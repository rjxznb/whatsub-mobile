import Foundation
import WebKit

/// Errors thrown by CaptionExtractor.
enum CaptionError: Error, LocalizedError {
    case timeout
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "未捕获到字幕，确认已挂 VPN 且该视频有字幕"
        case .emptyResult:
            return "字幕解析结果为空，请确认该视频有英文字幕"
        }
    }
}

/// Headless YouTube caption extractor.
/// Loads the YouTube watch page in an off-screen WKWebView with the caption
/// hook installed, awaits the first non-empty timedtext capture, parses it
/// with `parseTimedtextJson3`, and maps SpikeCue → Cue.
///
/// Must run on the main actor (WKWebView is main-thread only).
@MainActor
final class CaptionExtractor: NSObject {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[SpikeCue], Error>?
    private var resumed = false

    func extract(videoId: String) async throws -> [Cue] {
        let spikeCues = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<[SpikeCue], Error>) in
            self.continuation = cont
            self.resumed = false
            self.setupWebView(videoId: videoId)
        }
        // Map SpikeCue → Cue (translation/highlights empty until AnalysisEngine runs).
        return spikeCues.map { spike in
            Cue(index: spike.idx,
                time: spike.time,
                endTime: spike.end,
                text: spike.text)
        }
    }

    private func setupWebView(videoId: String) {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // Install hook in the page world at document start.
        let hook = WKUserScript(
            source: CaptionHookJS.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        cfg.userContentController.addUserScript(hook)
        cfg.userContentController.add(self, contentWorld: .page, name: "whatsubCaptions")

        let web = WKWebView(frame: .zero, configuration: cfg)
        // Keep WKWebView alive for the duration.
        self.webView = web

        // Load watch page with CC forced on.
        let urlString = "https://www.youtube.com/watch?v=\(videoId)&cc_load_policy=1"
        guard let url = URL(string: urlString) else {
            resumeOnce(throwing: CaptionError.emptyResult)
            return
        }
        web.load(URLRequest(url: url))

        // Timeout after 25 seconds.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            self?.resumeOnce(throwing: CaptionError.timeout)
        }
    }

    /// Resumes the continuation exactly once. Subsequent calls are no-ops.
    private func resumeOnce(with cues: [SpikeCue]) {
        guard !resumed else { return }
        resumed = true
        webView = nil  // release the WKWebView
        continuation?.resume(returning: cues)
        continuation = nil
    }

    private func resumeOnce(throwing error: Error) {
        guard !resumed else { return }
        resumed = true
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
        guard message.name == "whatsubCaptions",
              let dict = message.body as? [String: Any],
              let body = dict["body"] as? String else { return }

        let data = Data(body.utf8)
        let cues = parseTimedtextJson3(data)
        guard !cues.isEmpty else { return }

        // Must dispatch to main actor since resumeOnce touches actor-isolated state.
        Task { @MainActor [weak self] in
            self?.resumeOnce(with: cues)
        }
    }
}
