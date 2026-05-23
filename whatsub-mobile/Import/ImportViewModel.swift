import Foundation

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
        /// Caption extraction failed — push to desktop is available.
        case extractFailed(message: String)
        case pushing
        /// URL successfully enqueued to the backend import queue.
        case pushedToDesktop
    }

    @Published var state: State = .idle

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
        do {
            let extractor = CaptionExtractor()
            cues = try await extractor.extract(videoId: resolvedId)
        } catch {
            // Caption extraction failed — likely no captions on this video.
            // Offer the user the option to push to desktop for whisper processing.
            state = .extractFailed(message: error.localizedDescription)
            return
        }
        rawCues = cues

        // Step 2: Guard LLM configured.
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            state = .error("请先配置 LLM（我的 → LLM 设置）")
            return
        }

        // Step 3: Analyse with progress reporting.
        state = .analyzing(done: 0, total: 1)
        let engine = AnalysisEngine(client: OpenAICompatibleClient(settings: settings))
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

    // MARK: - Step 1b: Push caption-less URL to desktop import queue

    func pushToDesktop(token: String) async {
        let url = resolvedSourceURL.isEmpty ? "https://www.youtube.com/watch?v=\(videoId)" : resolvedSourceURL
        state = .pushing
        do {
            try await WhatsubAPI.shared.enqueueImport(url: url, token: token)
            state = .pushedToDesktop
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
