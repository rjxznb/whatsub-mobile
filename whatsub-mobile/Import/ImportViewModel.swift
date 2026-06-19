import Foundation
import WebKit

@MainActor
final class ImportViewModel: ObservableObject {

    enum State {
        case idle
        case extracting
        case analyzing(done: Int, total: Int)
        case preview
        case syncing
        case done
        case error(String)
        /// Caption extraction failed — push to desktop is available. `debug`
        /// is the CaptionExtractor's full event log surfaced via the
        /// 「查看诊断」 button so users can self-triage instead of guessing
        /// (or sending us a screenshot of a one-line error).
        case extractFailed(message: String, debug: [String])
        case pushing
        /// URL successfully enqueued to the backend import queue.
        case pushedToDesktop
        /// A non-YouTube source (Bilibili / other) that has no client-side
        /// caption path — offer to push it to the desktop queue.
        case needsDesktop(message: String)
        /// Push blocked by the OSS-video quota cap. Carries used/limit for display
        /// + the license-holder upsell.
        case quotaWall(used: Int, limit: Int)
    }

    @Published var state: State = .idle
    /// The hidden WKWebView used by CaptionExtractor — published so ImportView
    /// can mount it during the .extracting phase. Mounting is required (vs.
    /// keeping it detached) because YouTube's player uses IntersectionObserver
    /// + document.visibilityState to detect off-screen players and suspends
    /// caption-track loading on what it thinks is a hidden tab. See
    /// `WKWebViewHost.swift`.
    @Published var liveWebView: WKWebView?
    /// Gates the visible reveal of `liveWebView` in ImportView. False during
    /// the warmup phase (when the WebView is on youtube.com homepage showing
    /// an unrelated auto-preview video that would confuse the user), flipped
    /// true once CaptionExtractor navigates to the actual target /watch URL.
    @Published var liveWebViewWatching: Bool = false

    /// Extracted + analysed result, set once analysis completes.
    private(set) var result: AnalysisJson?
    /// Raw extracted cues (pre-analysis); kept for SRT generation.
    private(set) var rawCues: [Cue] = []
    private(set) var videoId: String = ""
    private(set) var title: String = ""
    /// The full YouTube watch URL entered/resolved by the user, kept so
    /// pushToDesktop can enqueue it without requiring UI re-entry.
    private(set) var resolvedSourceURL: String = ""

    // MARK: - Step 1: Extract + Analyse

    func run(urlOrId: String) async {
        let trimmed = urlOrId.trimmingCharacters(in: .whitespacesAndNewlines)

        // Non-YouTube URLs have no phone-side caption path (Bilibili CC is
        // Chinese/absent). Route straight to the desktop queue. A bare 11-char
        // YouTube id has no "://" → falls through to the YouTube path below.
        if trimmed.contains("://"), VideoSource.from(url: trimmed) != .youtube {
            resolvedSourceURL = trimmed
            videoId = ""
            title = trimmed
            state = .needsDesktop(message: "B站 / 其它来源无法在手机端取字幕，可推送到桌面端用 whisper 转录 + 解析（需桌面在线且登录同一账号）。")
            return
        }

        // Resolve video ID — accept a raw 11-char id or a full YouTube URL.
        let resolvedId: String
        if let fromURL = extractYouTubeID(trimmed) {
            resolvedId = fromURL
        } else if trimmed.count == 11, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            resolvedId = trimmed
        } else {
            state = .error("无法识别的 YouTube URL 或 ID")
            return
        }
        videoId = resolvedId
        title = resolvedId  // v1 fallback: use videoId as title
        resolvedSourceURL = "https://www.youtube.com/watch?v=\(resolvedId)"

        // Step 1: Extract captions.
        state = .extracting
        let cues: [Cue]
        let extractor = CaptionExtractor()
        liveWebViewWatching = false
        do {
            cues = try await extractor.extract(
                videoId: resolvedId,
                onWebViewReady: { [weak self] web in
                    // Publish the WebView so ImportView can host it in the
                    // SwiftUI tree (still invisible during warmup, per
                    // `liveWebViewWatching`).
                    self?.liveWebView = web
                },
                onWatchNavigation: { [weak self] in
                    // Warmup ended, watch URL load starting — reveal the
                    // WebView so the user sees their actual video loading.
                    self?.liveWebViewWatching = true
                }
            )
        } catch {
            // Caption extraction failed. Surface the rich debug log so the
            // user can hit 「查看诊断」 and see which step actually died —
            // far more actionable than the localized one-liner alone.
            state = .extractFailed(
                message: error.localizedDescription,
                debug: extractor.debugLog
            )
            liveWebView = nil  // teardown the host
            liveWebViewWatching = false
            return
        }
        // Success — drop the host so the WebView gets deallocated.
        liveWebView = nil
        liveWebViewWatching = false
        rawCues = cues
        // Replace the videoId placeholder title with the real YouTube title
        // (best-effort; VPN is on during import so youtube.com oEmbed is reachable).
        if let real = await Self.fetchYouTubeTitle(videoId: resolvedId), !real.isEmpty {
            title = real
        }

        // Step 2: Guard LLM configured.
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            state = .error("请先配置 LLM（我的 → LLM 设置）")
            return
        }

        // Step 3: Analyse with progress reporting.
        state = .analyzing(done: 0, total: 1)
        let engine = AnalysisEngine(client: ChatCompletionsClient(settings: settings))
        do {
            let analysis = try await engine.analyze(cues) { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.state = .analyzing(done: done, total: total)
                }
            }
            result = analysis
            state = .preview
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Fetch the real video title via YouTube oEmbed (best-effort; nil on any failure).
    private static func fetchYouTubeTitle(videoId: String) async -> String? {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")
        comps?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoId)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps?.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else { return nil }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Step 1b: Push caption-less URL to desktop import queue

    /// Directly enqueue an entered/shared URL to the desktop queue (the explicit
    /// "推送到桌面" choice — bypasses on-phone caption extraction).
    /// `email` (when available) is forwarded to `pushToDesktop` so it can start
    /// the Live Activity scoped to that user. Optional — Live Activity is
    /// best-effort; without an email we still enqueue normally.
    func pushURL(_ urlOrId: String, token: String, email: String? = nil) async {
        let trimmed = urlOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedSourceURL = trimmed.contains("://")
            ? trimmed
            : (VideoSource.isLikelyYouTubeId(trimmed) ? "https://www.youtube.com/watch?v=\(trimmed)" : trimmed)
        await pushToDesktop(token: token, email: email)
    }

    func pushToDesktop(token: String, email: String? = nil) async {
        let url = resolvedSourceURL.isEmpty ? "https://www.youtube.com/watch?v=\(videoId)" : resolvedSourceURL
        state = .pushing
        do {
            try await WhatsubAPI.shared.enqueueImport(url: url, token: token)
            // Start (or refresh) the Live Activity for the import queue so the
            // user has lock-screen / Dynamic Island visibility into desktop
            // processing. Best-effort — Activity failure means the in-app
            // queue view still works. Done BEFORE the state transition so
            // the lock-screen card appears in the same tick the success UI
            // does.
            if let email = email {
                let initial = ImportActivityAttributes.ContentState(
                    inProgress: 1,
                    completed: 0,
                    failed: 0,
                    recentTitle: title
                )
                await LiveActivityCoordinator.shared.ensureActivity(
                    forUserEmail: email,
                    initialState: initial
                )
            }
            state = .pushedToDesktop
        } catch APIError.quotaExceeded(let used, let limit) {
            state = .quotaWall(used: used, limit: limit)
        } catch let e as APIError {
            state = .error(e.chinese)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Step 2: Sync to cloud

    func sync(token: String) async {
        guard let analysis = result else {
            state = .error("没有分析结果，请重新导入")
            return
        }
        state = .syncing

        let srt = buildSRT(from: rawCues)
        let sourceUrl = "https://www.youtube.com/watch?v=\(videoId)"
        // Fetch the YouTube cover now (VPN is on for the import) + ship it as
        // thumbData so the backend serves a China-reachable thumbnail — the
        // imported video then shows a cover in the Library list WITHOUT VPN.
        let thumbData = await fetchThumbBase64(videoId: videoId)

        do {
            try await WhatsubAPI.shared.syncLibraryEntry(
                youtubeId: videoId,
                sourceUrl: sourceUrl,
                title: title,
                durationSec: nil,
                transcriptSrt: srt,
                analysis: analysis,
                thumbData: thumbData,
                token: token
            )
            state = .done
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Best-effort: fetch the YouTube cover (mqdefault.jpg) + base64. Returns nil
    /// on any failure (entry falls back to the i.ytimg URL, VPN-only).
    private func fetchThumbBase64(videoId: String) async -> String? {
        guard let url = URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg") else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
            return data.base64EncodedString()
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func buildSRT(from cues: [Cue]) -> String {
        cues.enumerated().map { (i, cue) in
            let start = srtTimestamp(cue.time)
            let end = srtTimestamp(cue.endTime)
            return "\(i + 1)\n\(start) --> \(end)\n\(cue.text)"
        }.joined(separator: "\n\n")
    }

    private func srtTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let ms = Int((seconds - Double(total)) * 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
