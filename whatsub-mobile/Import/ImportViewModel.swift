import Foundation

@MainActor
final class ImportViewModel: ObservableObject {

    enum State {
        case idle
        case extracting
        /// Streaming AI analysis. `cueCount` lets the UI render a time
        /// estimate ("约 1 分钟") in addition to the live done/total bar.
        case analyzing(done: Int, total: Int, cueCount: Int)
        case preview
        case syncing
        case done
        case error(String)
        /// Caption extraction failed — push to desktop is available. `debug`
        /// is the extractor's per-step event log surfaced via the
        /// 「查看诊断」 button so users can self-triage instead of guessing
        /// (or sending us a screenshot of a one-line error).
        case extractFailed(message: String, debug: [String])
        case pushing
        /// URL successfully enqueued to the backend import queue.
        /// `desktopOffline` = the backend hasn't seen the user's desktop
        /// client touch the queue recently (poll cadence is 30s; we warn
        /// past 120s) — the success screen shows a prominent "打开桌面端"
        /// reminder so the task doesn't sit in the queue unnoticed forever.
        case pushedToDesktop(desktopOffline: Bool)
        /// A non-YouTube source (Bilibili / other) that has no client-side
        /// caption path — offer to push it to the desktop queue.
        case needsDesktop(message: String)
        /// Push blocked by the OSS-video quota cap. Carries used/limit for display
        /// + the license-holder upsell.
        case quotaWall(used: Int, limit: Int)
    }

    @Published var state: State = .idle

    /// The in-flight extract→analyse→sync run. Owned here (not created ad-hoc
    /// by the View) so dismissing the import sheet can actually CANCEL it.
    /// Before 2026-07-20 the View spawned a detached `Task {}`: closing the
    /// sheet only tore down the UI while the run kept going and auto-synced a
    /// cloud entry the user believed they'd cancelled — silently consuming one
    /// of the 3 free video slots.
    private var workTask: Task<Void, Never>?

    /// Start the full import run, replacing any previous one.
    func start(urlOrId: String, token: String, email: String? = nil) {
        workTask?.cancel()
        workTask = Task { [weak self] in
            await self?.run(urlOrId: urlOrId, token: token, email: email)
        }
    }

    /// Start a re-run of JUST the analysis (error-screen retry button).
    func startRetryAnalysis(token: String) {
        workTask?.cancel()
        workTask = Task { [weak self] in
            await self?.retryAnalysisOnly(token: token)
        }
    }

    /// Cancel whatever is running. Safe to call when nothing is.
    /// The extracted captions stay in the on-disk cache — that's harmless and
    /// makes a later re-import instant; only the network work stops.
    func cancelWork() {
        workTask?.cancel()
        workTask = nil
    }

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

    func run(urlOrId: String, token: String, email: String? = nil) async {
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
        // 2026-06-19: pure-Swift Innertube extractor — see spec
        // docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md.
        var debugLog: [String] = []
        do {
            cues = try await YouTubeCaptionExtractor.extract(
                videoId: resolvedId,
                onProgress: { event in debugLog.append(event) }
            )
        } catch {
            state = .extractFailed(
                message: error.localizedDescription,
                debug: debugLog
            )
            return
        }
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

        // Step 3: Run AI analysis + auto-sync. Per user feedback
        // 2026-06-21: drop the manual "开始 AI 解析" + "同步到云库"
        // confirmation steps — once captions are extracted the user's
        // intent is obviously to land the entry in the cloud library.
        // Two manual taps were friction without value.
        await performAnalysis(rawCues, token: token)
    }

    /// Re-run JUST the LLM analysis on the in-memory `rawCues`. Used by
    /// the error-screen「重试 AI 解析」button so a network-stage failure
    /// (VPN routing, key issue, etc.) doesn't force the user back through
    /// URL input + caption extraction. If somehow rawCues is empty (e.g.,
    /// after a process restart), falls back to .idle so the URL screen
    /// shows up.
    func retryAnalysisOnly(token: String) async {
        guard !rawCues.isEmpty else {
            state = .idle
            return
        }
        await performAnalysis(rawCues, token: token)
    }

    private func performAnalysis(_ cues: [Cue], token: String) async {
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            state = .error("请先配置 LLM（我的 → LLM 设置）")
            return
        }
        let cueCount = cues.count
        state = .analyzing(done: 0, total: 1, cueCount: cueCount)
        let engine = AnalysisEngine(client: ChatCompletionsClient(settings: settings))
        do {
            let analysis = try await engine.analyze(cues) { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.state = .analyzing(done: done, total: total, cueCount: cueCount)
                }
            }
            result = analysis
            // Cancelled while the last chunk was in flight? Then the sheet is
            // already gone — do NOT upload. This is the check that keeps a
            // "cancelled" import out of the user's cloud library + quota.
            try Task.checkCancellation()
            // Auto-sync immediately on analysis success — user requested
            // removal of the preview/sync confirmation step.
            await sync(token: token)
        } catch is CancellationError {
            // User closed the sheet. No error UI: nothing is on screen, and
            // the next open should start clean rather than land on a stale
            // failure page.
            state = .idle
        } catch {
            // Captions stay in memory (rawCues) so the error-screen retry
            // skips straight back to performAnalysis. The hint differs by
            // mode: relay users hit eversay.cc (suspect VPN MITM); BYOK
            // users hit their LLM vendor directly (suspect baseUrl /
            // model / key).
            let base = error.localizedDescription
            let hint: String
            if settings.useManagedRelay {
                hint = "\n\n字幕仍在内存里，点「重试 AI 解析」会跳过字幕抓取直接重跑 AI。最快恢复：关 VPN 后点重试。一劳永逸：见底部「VPN 规则」。"
            } else {
                hint = "\n\n字幕仍在内存里，点「重试 AI 解析」可以重试。报「200」通常是 baseUrl 或 model 名不对——检查「我的 → LLM 设置」里 baseUrl 是否带 `/v1` 后缀（DeepSeek 是 `https://api.deepseek.com/v1`）、model 是 `deepseek-chat` 之类厂商支持的型号。"
            }
            state = .error(base + hint)
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
            let seenSecondsAgo = try await WhatsubAPI.shared.enqueueImport(url: url, token: token)
            // Start (or refresh) the Live Activity for the import queue so the
            // user has lock-screen / Dynamic Island visibility into desktop
            // processing. Best-effort — Activity failure means the in-app
            // queue view still works. Done BEFORE the state transition so
            // the lock-screen card appears in the same tick the success UI
            // does.
            // iOS 16.2+ guard: ActivityKit is unavailable on 16.0.
            if #available(iOS 16.2, *) {
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
            }
            // Desktop poll cadence is 30s — not seen for 120s (4 missed
            // polls) or never seen ⇒ treat as offline. nil also covers an
            // old backend without the field: we then show the softer copy
            // only when we KNOW the desktop was just alive.
            let offline = seenSecondsAgo == nil || seenSecondsAgo! > 120
            state = .pushedToDesktop(desktopOffline: offline)
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
