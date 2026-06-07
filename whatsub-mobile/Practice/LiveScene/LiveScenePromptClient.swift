import Foundation

/// One-shot LLM call: `SceneContext` → `SpeakingPrompt`.
///
/// Routes through the user's configured LLM (managed relay by default,
/// BYOK if opted out) — same `ChatCompletionsClient` everything else
/// uses, so quota + auth + retry semantics are shared.
///
/// Lenient JSON decode + Chinese-string failure path mirrors
/// `RoleplayScenarioClient` and `PhotoAnalyzer` — see
/// `feedback_swift_result_string_compile` for why we don't use Swift's
/// `Result<_, String>`.
///
/// 2026-06-05.
struct LiveScenePromptClient {

    let chat: ([ChatMessage]) async throws -> String

    static func live(settings: LlmSettings = LlmSettingsStore.load()) -> LiveScenePromptClient {
        let client = ChatCompletionsClient(settings: settings)
        return LiveScenePromptClient { messages in
            try await client.chat(messages)
        }
    }

    func derive(scene: SceneContext) async -> PromptDerivationOutcome {
        let messages = LiveScenePrompts.promptDerivationMessages(scene: scene)
        let raw: String
        do {
            raw = try await chat(messages)
        } catch {
            // Unified taxonomy mapping — see RemoteFailure.from for the policy /
            // notConfigured / generic routing logic. The throw site doesn't need
            // to know about `subscribeUpsell`; it just hands the error to the
            // funnel.
            return .failure(RemoteFailure.from(error, fallback: "AI 给出题目时出了点状况"))
        }
        return parse(raw)
    }

    func parse(_ raw: String) -> PromptDerivationOutcome {
        let body = stripFences(raw)
        guard let data = body.data(using: .utf8) else {
            return .failure(.message("AI 返回的内容没读懂，稍后再试。"))
        }
        do {
            let wire = try JSONDecoder().decode(WireSpeakingPrompt.self, from: data)
            return .success(wire.toModel())
        } catch {
            // The head=... is for our forensic logs; the user only sees the
            // message string in the banner.
            return .failure(.message("AI 返回的内容没读懂，再试一次。"))
        }
    }

    // MARK: - lenient wire shape

    /// All fields tolerated as missing or wrong-typed — fallbacks keep the
    /// session usable rather than nuking the whole exercise.
    private struct WireSpeakingPrompt: Decodable {
        let promptEn: String
        let sampleAnswer: String
        let sampleAnswerZh: String
        let targetVocab: [String]
        let difficulty: Int

        enum CodingKeys: String, CodingKey {
            case promptEn, prompt_en
            case sampleAnswer, sample_answer
            case sampleAnswerZh, sample_answer_zh
            case targetVocab, target_vocab
            case difficulty
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.promptEn = (try? c.decode(String.self, forKey: .promptEn))
                ?? (try? c.decode(String.self, forKey: .prompt_en))
                ?? "Describe what you see in this scene in 2-3 English sentences."
            self.sampleAnswer = (try? c.decode(String.self, forKey: .sampleAnswer))
                ?? (try? c.decode(String.self, forKey: .sample_answer))
                ?? ""   // empty fallback — 提示 第二级 + review 都 graceful skip
            self.sampleAnswerZh = (try? c.decode(String.self, forKey: .sampleAnswerZh))
                ?? (try? c.decode(String.self, forKey: .sample_answer_zh))
                ?? ""   // empty fallback — 提示 第一级 graceful skip
            let raw = (try? c.decode([String].self, forKey: .targetVocab))
                ?? (try? c.decode([String].self, forKey: .target_vocab))
                ?? []
            self.targetVocab = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            // Difficulty: int OR string OR missing → 2 (mid).
            if let i = try? c.decode(Int.self, forKey: .difficulty) {
                self.difficulty = max(1, min(3, i))
            } else if let s = try? c.decode(String.self, forKey: .difficulty),
                      let i = Int(s) {
                self.difficulty = max(1, min(3, i))
            } else {
                self.difficulty = 2
            }
        }

        func toModel() -> SpeakingPrompt {
            // Cap targetVocab at 5 even if the LLM ignored the prompt and
            // returned more — same defensive prefix(5) as RoleplayScenario.
            SpeakingPrompt(
                promptEn: promptEn.trimmingCharacters(in: .whitespacesAndNewlines),
                sampleAnswer: sampleAnswer.trimmingCharacters(in: .whitespacesAndNewlines),
                sampleAnswerZh: sampleAnswerZh.trimmingCharacters(in: .whitespacesAndNewlines),
                targetVocab: Array(targetVocab.prefix(5)),
                difficulty: difficulty
            )
        }
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
