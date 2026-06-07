import Foundation

/// One-shot LLM call: `(SpeakingPrompt, user transcript)` → `SceneGrade`.
///
/// Same shape as `LiveScenePromptClient` — single async call, lenient
/// JSON decode, Chinese error string on failure (no Swift `Result<_,
/// String>`).
///
/// 2026-06-05.
struct LiveSceneGrader {

    let chat: ([ChatMessage]) async throws -> String

    static func live(settings: LlmSettings = LlmSettingsStore.load()) -> LiveSceneGrader {
        let client = ChatCompletionsClient(settings: settings)
        return LiveSceneGrader { messages in
            try await client.chat(messages)
        }
    }

    func grade(prompt: SpeakingPrompt, userTranscript: String) async -> GradingOutcome {
        let messages = LiveScenePrompts.gradingMessages(prompt: prompt, userTranscript: userTranscript)
        let raw: String
        do {
            raw = try await chat(messages)
        } catch {
            return .failure(RemoteFailure.from(error, fallback: "AI 给你打分时出了点状况"))
        }
        return parse(raw, expectedVocab: prompt.targetVocab)
    }

    func parse(_ raw: String, expectedVocab: [String]) -> GradingOutcome {
        let body = stripFences(raw)
        guard let data = body.data(using: .utf8) else {
            return .failure(.message("AI 返回的内容没读懂，稍后再试。"))
        }
        do {
            let wire = try JSONDecoder().decode(WireGrade.self, from: data)
            return .success(wire.toModel(expectedVocab: expectedVocab))
        } catch {
            return .failure(.message("AI 返回的内容没读懂，再试一次。"))
        }
    }

    // MARK: - lenient wire shape

    private struct WireGrade: Decodable {
        let score: Int
        let feedback: String
        let vocabHits: [WireHit]

        enum CodingKeys: String, CodingKey {
            case score, feedback
            case vocabHits, vocab_hits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Score: tolerate string "4" or float 3.5 — round + clamp to 1..5.
            if let i = try? c.decode(Int.self, forKey: .score) {
                self.score = max(1, min(5, i))
            } else if let d = try? c.decode(Double.self, forKey: .score) {
                self.score = max(1, min(5, Int(d.rounded())))
            } else if let s = try? c.decode(String.self, forKey: .score), let i = Int(s) {
                self.score = max(1, min(5, i))
            } else {
                self.score = 3   // neutral default — failure mode is "couldn't tell"
            }
            self.feedback = (try? c.decode(String.self, forKey: .feedback)) ?? ""
            // modelAnswer field was removed from the grader prompt — review
            // screen now uses `prompt.sampleAnswer` (pre-computed) instead.
            // If a stale LLM emits modelAnswer we just ignore it.
            self.vocabHits = (try? c.decode([WireHit].self, forKey: .vocabHits))
                ?? (try? c.decode([WireHit].self, forKey: .vocab_hits))
                ?? []
        }

        /// Pad / trim to match the expected vocab list so the UI can iterate
        /// 1:1 without index-out-of-range fears. Missing slots get `attempted:
        /// false, correct: false` — same as "LLM didn't grade this phrase".
        func toModel(expectedVocab: [String]) -> SceneGrade {
            var hits: [VocabHit] = []
            for v in expectedVocab {
                if let match = vocabHits.first(where: { $0.phrase?.lowercased() == v.lowercased() }) {
                    hits.append(VocabHit(
                        phrase: v,
                        attempted: match.attempted ?? false,
                        correct: match.correct ?? false,
                        note: match.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    ))
                } else {
                    hits.append(VocabHit(phrase: v, attempted: false, correct: false, note: ""))
                }
            }
            return SceneGrade(
                score: score,
                feedback: feedback.trimmingCharacters(in: .whitespacesAndNewlines),
                vocabHits: hits
            )
        }
    }

    private struct WireHit: Decodable {
        let phrase: String?
        let attempted: Bool?
        let correct: Bool?
        let note: String?
    }

    // MARK: - markdown-fence stripping (shared pattern)

    func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...])
        }
        if let lastFence = t.range(of: "```", options: .backwards) {
            t = String(t[..<lastFence.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
