import Foundation

struct AnalysisEngine {
    let client: OpenAICompatibleClient

    static func batches(_ cues: [Cue], size: Int = 50) -> [[Cue]] {
        stride(from: 0, to: cues.count, by: size).map { Array(cues[$0..<min($0 + size, cues.count)]) }
    }

    /// Decode JSON-Lines per-cue output into Cue[]. Skips blank/non-JSON lines
    /// and any stray summary line. Reuses the existing tolerant `Cue` decoder.
    static func parseCueLines(_ raw: String) -> [Cue] {
        var out: [Cue] = []
        for line in raw.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("{"), let data = s.data(using: .utf8) else { continue }
            // skip summary lines
            if s.contains("\"type\":\"summary\"") || s.contains("\"keyPhrases\"") { continue }
            if let cue = try? JSONDecoder().decode(Cue.self, from: data) { out.append(cue) }
        }
        return out
    }

    static func parseSummaryLine(_ raw: String) -> [KeyPhrase] {
        for line in raw.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.contains("\"keyPhrases\""), let data = s.data(using: .utf8) else { continue }
            struct S: Decodable { let keyPhrases: [KeyPhrase] }
            if let parsed = try? JSONDecoder().decode(S.self, from: data) { return parsed.keyPhrases }
        }
        return []
    }

    /// Full analysis. `onProgress(done, total)` for the UI.
    func analyze(_ cues: [Cue], onProgress: @escaping (Int, Int) -> Void) async throws -> AnalysisJson {
        let batched = Self.batches(cues)
        var subtitles: [Cue] = []
        for (i, batch) in batched.enumerated() {
            let content = try await client.chat([
                ChatMessage(role: "system", content: AnalysisPrompts.system),
                ChatMessage(role: "user", content: AnalysisPrompts.userPrompt(batch)),
            ])
            subtitles.append(contentsOf: Self.parseCueLines(content))
            onProgress(i + 1, batched.count + 1)
        }
        // Re-index sequentially (LLM should preserve, but be safe).
        for i in subtitles.indices { subtitles[i].index = i }
        // Summary (keyPhrases).
        var keyPhrases: [KeyPhrase] = []
        if !subtitles.isEmpty {
            let summary = try await client.chat([
                ChatMessage(role: "system", content: AnalysisPrompts.system),
                ChatMessage(role: "user", content: AnalysisPrompts.summaryPrompt(subtitles)),
            ])
            keyPhrases = Self.parseSummaryLine(summary)
        }
        onProgress(batched.count + 1, batched.count + 1)
        return AnalysisJson.assembled(subtitles: subtitles, keyPhrases: keyPhrases)
    }
}
