import Foundation

/// Subtitle analysis pipeline. Mirrors `whatsub-releases/Get_Video/client/
/// src/llm/analyze.ts`'s shape: streamed JSONL per cue (phase 1) +
/// one streamed summary call at the end (phase 2).
///
/// Pre-2026-06-21 this used `client.chat()` (non-streaming) which capped
/// at max_tokens=4096 and locked us out of DeepSeek v4 reasoning models
/// (the V4 family burns the budget on a reasoning trace and leaves
/// `content` empty for long batches). The streaming path:
///   - Removes the per-batch length cap (max_tokens=16384, plus the
///     server streams whatever fits).
///   - Yields each cue as soon as the LLM emits its JSON line,
///     giving the UI per-cue progress (you see translations land
///     in real time, not in 50-cue chunks).
///   - Tolerates DeepSeek v4-flash's `reasoning_content` channel —
///     ChatCompletionsClient.streamChat falls back to
///     reasoning_content when content is empty so any "think out
///     loud + emit JSONL" model just works.
struct AnalysisEngine {
    let client: ChatCompletionsClient

    static func batches(_ cues: [Cue], size: Int = 50) -> [[Cue]] {
        stride(from: 0, to: cues.count, by: size).map { Array(cues[$0..<min($0 + size, cues.count)]) }
    }

    /// Decode one JSON object (from the streaming parser) into a Cue
    /// when its shape matches our cue schema. Returns nil for summary
    /// objects (which carry `keyPhrases` instead of `text`/`time`).
    static func parseCue(_ obj: Any) -> Cue? {
        guard let dict = obj as? [String: Any] else { return nil }
        // Summary lines carry keyPhrases — skip cleanly so they don't
        // pollute the cue list.
        if dict["keyPhrases"] != nil || (dict["type"] as? String) == "summary" {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Cue.self, from: data)
    }

    /// Try to decode a summary object's keyPhrases.
    static func parseSummary(_ obj: Any) -> [KeyPhrase]? {
        guard let dict = obj as? [String: Any],
              dict["keyPhrases"] != nil,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        struct S: Decodable { let keyPhrases: [KeyPhrase] }
        return (try? JSONDecoder().decode(S.self, from: data))?.keyPhrases
    }

    /// Run the analysis. `onProgress(done, total)` ticks at cue
    /// granularity now (was per-batch before the streaming switch), so
    /// the UI sees a smooth bar instead of long pauses between jumps.
    func analyze(_ cues: [Cue], onProgress: @escaping (Int, Int) -> Void) async throws -> AnalysisJson {
        // Cancellation (2026-07-20): closing the import sheet cancels the
        // owning Task. Without these checks the run continued in the
        // background and auto-synced a cloud entry the user thought they'd
        // cancelled — burning one of their 3 free video slots.
        try Task.checkCancellation()
        let batched = Self.batches(cues)
        var subtitles: [Cue] = []
        let totalCues = cues.count
        // Phase 1: per-cue stream, batch by batch.
        for batch in batched {
            // Between batches is the cheapest place to bail: the previous
            // batch's tokens are already paid for, the next one isn't.
            try Task.checkCancellation()
            let parser = JsonLineParser()
            let stream = client.streamChat([
                ChatMessage(role: "system", content: AnalysisPrompts.system),
                ChatMessage(role: "user", content: AnalysisPrompts.userPrompt(batch)),
            ])
            for try await chunk in stream {
                parser.feed(chunk) { obj in
                    if let cue = Self.parseCue(obj) {
                        subtitles.append(cue)
                        onProgress(subtitles.count, totalCues + 1)
                    }
                }
            }
            parser.flush { obj in
                if let cue = Self.parseCue(obj) {
                    subtitles.append(cue)
                    onProgress(subtitles.count, totalCues + 1)
                }
            }
        }
        // Re-index sequentially (LLM should preserve, but be safe).
        for i in subtitles.indices { subtitles[i].index = i }

        // Phase 2: streamed summary call across the whole transcript.
        // Wrapped: losing the summary should NOT abort the run since the
        // cue analyses are usable on their own.
        var keyPhrases: [KeyPhrase] = []
        if !subtitles.isEmpty {
            try Task.checkCancellation()
            do {
                let parser = JsonLineParser()
                let stream = client.streamChat([
                    ChatMessage(role: "system", content: AnalysisPrompts.system),
                    ChatMessage(role: "user", content: AnalysisPrompts.summaryPrompt(subtitles)),
                ])
                for try await chunk in stream {
                    parser.feed(chunk) { obj in
                        if let kp = Self.parseSummary(obj) { keyPhrases = kp }
                    }
                }
                parser.flush { obj in
                    if let kp = Self.parseSummary(obj) { keyPhrases = kp }
                }
            } catch is CancellationError {
                // Must NOT be swallowed like a summary failure — otherwise a
                // cancel landing during phase 2 would still return a result
                // and the caller would sync it.
                throw CancellationError()
            } catch {
                // Summary lost — keep the cues we collected.
            }
        }
        onProgress(totalCues + 1, totalCues + 1)
        return AnalysisJson.assembled(subtitles: subtitles, keyPhrases: keyPhrases)
    }
}
