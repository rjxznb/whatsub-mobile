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
    /// YouTube redirected to accounts.google.com mid-extraction — meaning
    /// BotGuard wants a signed-in session before serving captions. We
    /// can't satisfy this from a cookie-less WKWebView; pushing to desktop
    /// (which runs yt-dlp with a real cookies file) is the only path.
    case requiresLogin

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "未捕获到字幕。可能是 YouTube 对本会话反爬升级了，或视频本身没有英文字幕。点「查看诊断」看挂在哪一步，或「推送到桌面端」让 Whisper 转录。"
        case .emptyResult:
            return "字幕解析结果为空，请确认该视频有英文字幕。"
        case .requiresLogin:
            return "YouTube 反爬把字幕接口锁了（即使有登录入口也救不回来 — BotGuard 看 WebKit 指纹拒绝服务）。点「推送到桌面端」让桌面 yt-dlp 用真实 cookies 抓字幕，这条路目前 100% 稳。"
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
    /// the SwiftUI view tree. The hosting is needed for YouTube's player
    /// to see a non-zero viewport, but ImportView keeps the view hidden
    /// until `onWatchNavigation` fires — otherwise the user sees the
    /// warmup homepage's auto-playing preview banner for the first ~3.5s,
    /// which looks like a bug ("why is it showing me a different video?").
    /// Default no-ops preserve callers that don't host (tests).
    func extract(videoId: String,
                 onWebViewReady: @MainActor (WKWebView) -> Void = { _ in },
                 onWatchNavigation: @MainActor @escaping () -> Void = {})
        async throws -> [Cue]
    {
        appendDebug("extract(videoId=\(videoId)) start")
        self.onWatchNavigation = onWatchNavigation
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

    /// Stored so `webView(_:didFinish:)` can navigate to the watch URL once
    /// the homepage warmup completes (or its 2s window elapses).
    private var pendingVideoId: String?
    private var warmupComplete = false
    /// Fired exactly once when navigateToWatch starts the watch-URL load,
    /// so ImportView can reveal the WKWebView at that moment instead of
    /// during warmup (which shows the homepage's unrelated preview video).
    private var onWatchNavigation: @MainActor () -> Void = {}

    private func setupWebView(videoId: String,
                              onWebViewReady: @MainActor (WKWebView) -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // 2026-06-18 — explicit persistent cookie store. WKWebViewConfiguration
        // already defaults to .default() (persistent) on iOS, but stating it
        // here makes the intent obvious for future readers: we WANT cookies
        // to survive across extractor instances so YouTube's BotGuard
        // reputation accumulates ("repeat visitor" beats "fresh bot every
        // time"). Don't change to `.nonPersistent()` — that's what bit us.
        cfg.websiteDataStore = WKWebsiteDataStore.default()

        // 2026-06-18 — Inject the target videoId BEFORE the hook so JS can
        // gate all caption-posting on "are we currently on the right /watch
        // page". Without this, the hook posts captions from:
        //   (a) the warmup homepage's auto-preview video, OR
        //   (b) any video YouTube navigates us to via recommendation clicks.
        // Both produce 404s that look like "the target video has no
        // captions" when in fact we just asked for the wrong URL's
        // timedtext token. Sanitized to prevent JS injection — videoIds are
        // 11 alphanum chars, but defensively strip anything else.
        let safeId = videoId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }.map(String.init).joined()
        let targetScript = WKUserScript(
            source: "window.__whatsubTargetVideoId = '\(safeId)';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        cfg.userContentController.addUserScript(targetScript)

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

        // 2026-06-18 — Two-step navigation: homepage warmup, then watch URL.
        // Loading youtube.com/ first gives YouTube a "user visited the
        // homepage then clicked a video" interaction trail in the visitor-
        // cookie state. Combined with persistent data store above, this is
        // the cheapest way to look like a returning user — which is what
        // BotGuard's "real human vs bot" score actually looks at.
        pendingVideoId = videoId
        warmupComplete = false
        appendDebug("warmup: loading youtube.com")
        web.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))

        // Hard cap on warmup duration — if homepage didFinish never fires
        // (slow network, blocked domain), force the watch navigation after
        // 3.5s so we don't burn the full 25s budget on the warmup alone.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, !self.warmupComplete, !self.resumed else { return }
            self.appendDebug("warmup: max 3.5s elapsed, forcing watch navigation")
            self.navigateToWatch()
        }

        // Outer timeout — 25s from setup to first cues. Same budget as
        // before; warmup eats ~1.5-3.5s of that, leaving ~20s for the
        // watch URL + player + caption fetch.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            self?.appendDebug("timeout after 25s")
            self?.resumeOnce(throwing: CaptionError.timeout)
        }
    }

    /// Trigger the watch-URL navigation after warmup completes. Idempotent:
    /// the navigation delegate calls it on homepage didFinish, AND the
    /// 3.5s timer calls it as a fallback — only the first one runs.
    private func navigateToWatch() {
        guard !warmupComplete, let videoId = pendingVideoId, let web = webView else { return }
        warmupComplete = true
        let urlString = "https://www.youtube.com/watch?v=\(videoId)&cc_load_policy=1"
        guard let url = URL(string: urlString) else {
            appendDebug("invalid watch URL")
            resumeOnce(throwing: CaptionError.emptyResult)
            return
        }
        appendDebug("post-warmup: loading \(urlString)")
        // Tell ImportView to reveal the WKWebView NOW — we're about to load
        // the actual target video, so the user sees their video loading
        // instead of the warmup homepage's preview content.
        onWatchNavigation()
        web.load(URLRequest(url: url))
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
                    // 2026-06-18 — early abort on BotGuard login wall. The JS
                    // hook detects "the timedtext synth_fetch returned a 2MB
                    // HTML page" (sign-in wall, not json3) and fires this
                    // event. Without the abort, we'd wait out the 25s
                    // timeout on a video YT has already rejected.
                    if event == "login_wall_detected" {
                        self?.resumeOnce(throwing: CaptionError.requiresLogin)
                    }
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
            // Got a non-empty body but parsing yielded nothing.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendDebug("parser dropped body (len=\(body.count))")
                // 2026-06-18 — Swift-side fallback for the login-wall detector.
                // Real json3 captions are tiny (kilobytes); a huge unparseable
                // body is almost certainly the BotGuard sign-in HTML page.
                // Abort here so we don't sit on the 25s timeout — same
                // outcome as if the JS hook had caught it via its own
                // `login_wall_detected` heuristic.
                if body.count > 50_000 {
                    self.appendDebug("Swift-side login wall: \(body.count) bytes dropped → requiresLogin")
                    self.resumeOnce(throwing: CaptionError.requiresLogin)
                }
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

    /// Intercept ACTIVE sign-in redirects (`accounts.google.com` without the
    /// `passive=true` marker) so we throw .requiresLogin early instead of
    /// waiting out the 25s timeout. PASSIVE SSO probes (which YouTube fires
    /// unconditionally when loading the homepage to check for an existing
    /// Google session) get allowed through — they auto-bounce back to YT
    /// regardless of whether the user has a session and don't block caption
    /// extraction. Earlier versions blocked all accounts.google.com nav,
    /// which killed extraction for every video because the warmup load of
    /// youtube.com always triggered the passive probe. 2026-06-18.
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        if url.host?.contains("accounts.google.com") == true {
            let urlStr = url.absoluteString
            // Heuristics for "passive" probe (returns to YT no matter what):
            //   • passive=true query
            //   • signin_passive in the path or `next` param
            //   • uilel=3 (the "ambient" SSO entry point YouTube uses)
            // Any of these → allow the nav and keep extracting.
            let isPassive = urlStr.contains("passive=true")
                || urlStr.contains("signin_passive")
                || urlStr.contains("uilel=3")
            if isPassive {
                Task { @MainActor [weak self] in
                    self?.appendDebug("allowed passive SSO nav: \(urlStr.prefix(140))")
                }
                decisionHandler(.allow)
                return
            }
            // Real sign-in wall — abort.
            Task { @MainActor [weak self] in
                self?.appendDebug("blocked active sign-in nav: \(urlStr.prefix(140))")
                self?.resumeOnce(throwing: CaptionError.requiresLogin)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"
        Task { @MainActor [weak self] in self?.appendDebug("nav: start \(url)") }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendDebug("nav: finish \(url)")
            // If warmup just finished (homepage loaded), schedule the watch
            // navigation. 1.5s dwell on homepage so YouTube's analytics +
            // cookie state settle before we ask it for a video.
            if !self.warmupComplete, !url.contains("watch?v="), url.contains("youtube.com") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.navigateToWatch()
            }
        }
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
