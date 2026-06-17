import Foundation
import WebKit
import os.log

/// Errors thrown by CaptionExtractor. Failure-path detail is intentionally
/// terse here — the rich event-by-event diagnosis lives on the extractor's
/// `debugLog` property (publicly readable after a throw). ImportView surfaces
/// it via the 「查看诊断」 button on the failure screen so users don't have
/// to plug into Console.app to see where the pipeline died.
enum CaptionError: Error, LocalizedError {
    case timeout
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "未捕获到字幕。可能是该视频没有英文字幕，或 YouTube 又改了播放器接口路径。点「查看诊断」看到底哪一步挂了，或先点「推送到桌面端」让 Whisper 转录。"
        case .emptyResult:
            return "字幕解析结果为空，请确认该视频有英文字幕。"
        }
    }
}

/// Headless YouTube caption extractor.
///
/// 2026-06-17 — major reliability pass after a regression where mobile
/// extraction silently failed while the browser plugin kept working. Root
/// cause: YouTube tightened mobile-web detection; default iOS WKWebView UA
/// got served a downgraded player that (a) defaults CC OFF and (b)
/// migrated timedtext to the youtubei API. Fixes here, ranked by impact:
///
///   1. **Spoofs a desktop Chrome UA** so YouTube serves the same player
///      code the browser plugin sees. This alone restores most failures.
///   2. **Pairs with a hardened CaptionHookJS** that also matches the
///      youtubei.googleapis.com player API and synthesizes a direct
///      timedtext fetch when the player itself doesn't.
///   3. **Wires a second message handler `whatsubDebug`** plus a
///      `WKNavigationDelegate` so every key step in the pipeline lands
///      in an in-memory log. On timeout we dump the tail to OSLog so
///      we can diagnose silent failures from TestFlight reports without
///      guessing.
///
/// Must run on the main actor (WKWebView is main-thread only).
@MainActor
final class CaptionExtractor: NSObject {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[SpikeCue], Error>?
    private var resumed = false

    /// Rolling diagnostic log. Publicly readable so ImportView's
    /// 「查看诊断」 sheet can surface the full sequence of events to the
    /// user on failure — far more actionable than the single-line localized
    /// error string. Also still dumped to OSLog on every failure path.
    private(set) var debugLog: [String] = []
    private let log = Logger(subsystem: "cc.eversay.whatsub.mobile",
                             category: "CaptionExtractor")

    /// `onWebViewReady` lets the caller (ImportView) host the WKWebView in
    /// the SwiftUI view tree at near-zero opacity. Without view-hierarchy
    /// presentation YouTube's IntersectionObserver flags the player as
    /// off-screen → some videos refuse to load captions on a "hidden"
    /// player. Default no-op preserves callers that don't host (tests).
    func extract(videoId: String,
                 onWebViewReady: @MainActor (WKWebView) -> Void = { _ in })
        async throws -> [Cue]
    {
        appendDebug("extract(videoId=\(videoId)) start")
        let spikeCues = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<[SpikeCue], Error>) in
            self.continuation = cont
            self.resumed = false
            self.setupWebView(videoId: videoId, onWebViewReady: onWebViewReady)
        }
        // Map SpikeCue → Cue (translation/highlights empty until AnalysisEngine runs).
        return spikeCues.map { spike in
            Cue(index: spike.idx,
                time: spike.time,
                endTime: spike.end,
                text: spike.text)
        }
    }

    private func setupWebView(videoId: String,
                              onWebViewReady: @MainActor (WKWebView) -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // Install hook in the page world at document start so it runs
        // before the player's first network call.
        let hook = WKUserScript(
            source: CaptionHookJS.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        cfg.userContentController.addUserScript(hook)
        cfg.userContentController.add(self, contentWorld: .page, name: "whatsubCaptions")
        // 2026-06-17: second handler dedicated to telemetry. Separate from
        // the captions one so the success-path parsing logic doesn't need
        // to discriminate event kinds.
        cfg.userContentController.add(self, contentWorld: .page, name: "whatsubDebug")

        // 2026-06-18 — give the WebView REAL dimensions (was `.zero`) so
        // YouTube's IntersectionObserver and CSS viewport-based queries see
        // a "visible" player. With a zero-size view some videos refused to
        // load captions because the player thought it was off-screen and
        // suspended its caption track. The view still gets opacity ~0 from
        // its SwiftUI host (ImportView during the extracting phase) — the
        // user never sees it, but the YT player sees a non-zero viewport.
        let web = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180),
            configuration: cfg
        )
        // 2026-06-17 — CRITICAL: spoof a desktop Chrome UA so YouTube
        // serves the desktop player. The default iOS WKWebView UA was
        // getting the mobile-web player which has CC default OFF + uses
        // the youtubei API path — both regressed our extraction. Chrome
        // 130 is current as of 2026-06; bump occasionally if YouTube
        // starts flagging outdated UAs.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        web.navigationDelegate = self
        // Keep WKWebView alive for the duration.
        self.webView = web
        // 2026-06-18 — hand the view off to the SwiftUI host BEFORE load()
        // so the view tree mounts before the first script executes. Without
        // this, even with non-zero frame, the WebView isn't in a window
        // and YouTube sometimes still flags it as backgrounded.
        onWebViewReady(web)

        // Load watch page with CC forced on. cc_load_policy=1 is now
        // best-effort (YouTube respects it inconsistently), but combined
        // with the desktop UA above + the player-API synth fetch in
        // CaptionHookJS it's still helpful as a hint.
        let urlString = "https://www.youtube.com/watch?v=\(videoId)&cc_load_policy=1"
        guard let url = URL(string: urlString) else {
            appendDebug("invalid URL string")
            resumeOnce(throwing: CaptionError.emptyResult)
            return
        }
        appendDebug("loading \(urlString)")
        web.load(URLRequest(url: url))

        // Timeout after 25 seconds.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            self?.appendDebug("timeout after 25s")
            self?.resumeOnce(throwing: CaptionError.timeout)
        }
    }

    private func appendDebug(_ event: String) {
        let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000))
        debugLog.append("[\(ts)] \(event)")
        // Cap ring buffer so a chatty hook doesn't blow memory.
        if debugLog.count > 80 { debugLog.removeFirst() }
    }

    /// Dump the last N entries of the rolling log to OSLog. Visible via
    /// Console.app when the device is plugged into a Mac, or via
    /// `os_log` capture in TestFlight forensics. Called on every
    /// failure path so triage doesn't have to guess where things died.
    private func flushDebugToLog(reason: String) {
        let tail = debugLog.suffix(30).joined(separator: "\n  ")
        log.error("CaptionExtractor failed (\(reason, privacy: .public)). Last events:\n  \(tail, privacy: .public)")
    }

    /// Resumes the continuation exactly once. Subsequent calls are no-ops.
    private func resumeOnce(with cues: [SpikeCue]) {
        guard !resumed else { return }
        resumed = true
        appendDebug("success: \(cues.count) cues")
        webView = nil  // release the WKWebView
        continuation?.resume(returning: cues)
        continuation = nil
    }

    private func resumeOnce(throwing error: Error) {
        guard !resumed else { return }
        resumed = true
        flushDebugToLog(reason: error.localizedDescription)
        webView = nil  // release the WKWebView
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - WKScriptMessageHandler

extension CaptionExtractor: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "whatsubDebug" {
            // Telemetry side channel from the JS hook.
            if let dict = message.body as? [String: Any] {
                let event = (dict["event"] as? String) ?? "?"
                let info = (dict["info"] as? String) ?? ""
                Task { @MainActor [weak self] in
                    self?.appendDebug("js: \(event) \(info)")
                }
            }
            return
        }

        // Default: captions payload. Existing contract preserved.
        guard message.name == "whatsubCaptions",
              let dict = message.body as? [String: Any],
              let body = dict["body"] as? String else { return }

        let data = Data(body.utf8)
        let cues = parseTimedtextJson3(data)
        guard !cues.isEmpty else {
            // Got a non-empty body but parsing yielded nothing — log it so
            // we don't silently discard a successful capture that just
            // happened to be a format the parser doesn't know.
            Task { @MainActor [weak self] in
                self?.appendDebug("parser dropped body (len=\(body.count))")
            }
            return
        }

        // Must dispatch to main actor since resumeOnce touches actor-isolated state.
        Task { @MainActor [weak self] in
            self?.resumeOnce(with: cues)
        }
    }
}

// MARK: - WKNavigationDelegate

extension CaptionExtractor: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"
        Task { @MainActor [weak self] in self?.appendDebug("nav: start \(url)") }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"
        Task { @MainActor [weak self] in self?.appendDebug("nav: finish \(url)") }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let url = webView.url?.absoluteString ?? "?"
        let desc = error.localizedDescription
        Task { @MainActor [weak self] in self?.appendDebug("nav: fail \(url) — \(desc)") }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let url = webView.url?.absoluteString ?? "?"
        let desc = error.localizedDescription
        Task { @MainActor [weak self] in self?.appendDebug("nav: provisional-fail \(url) — \(desc)") }
    }
}
