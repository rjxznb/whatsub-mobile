import Foundation

/// One-shot LLM call that turns a Library video + the user's collected
/// phrases for that video into 1-3 `RoleplayScenario`s. The result is
/// shown in the picker; the user picks one and the orb session takes over.
///
/// Failure modes are first-class: the LLM can refuse, return junk, or
/// time out. The client never throws into the UI — it returns whatever
/// it could salvage (possibly empty), and the caller surfaces an error
/// or falls back to a stock scenario. Keeping the tab usable when the
/// LLM is down is more important than perfect scene quality.
struct RoleplayScenarioClient {

    let chat: ([ChatMessage]) async throws -> String

    /// Production wiring against the user's BYOK key.
    static func live(settings: LlmSettings) -> RoleplayScenarioClient {
        let client = ChatCompletionsClient(settings: settings)
        return RoleplayScenarioClient { messages in
            try await client.chat(messages)
        }
    }

    /// Derive scenarios from a Library entry. `corpusPhrases` are the user's
    /// own collected English phrases for THIS video (raw form, lowercased
    /// or not — the prompt normalizes them).
    ///
    /// Returns an empty array on a hard failure (network, JSON parse).
    /// Caller is expected to layer a stock fallback on top so the tab is
    /// never empty.
    func deriveScenarios(
        entry: LibraryEntryDetail,
        corpusPhrases: [String]
    ) async -> Result<[RoleplayScenario], String> {
        let summary = Self.subtitleSummary(entry.analysisJson.subtitles)
        let messages = RoleplayPrompts.scenePrompt(
            videoTitle: entry.title,
            subtitleSummary: summary,
            corpusPhrases: corpusPhrases
        )

        let raw: String
        do {
            raw = try await chat(messages)
        } catch let e as ChatCompletionsClient.LlmError {
            return .failure(e.errorDescription ?? "LLM 调用失败")
        } catch {
            return .failure("LLM 调用失败：\(error.localizedDescription)")
        }

        // The LLM sometimes wraps the JSON in markdown fences despite our
        // "no fences" instruction. Strip ```json ... ``` / ``` ... ```
        // before decoding.
        let body = Self.stripFences(raw)
        guard let data = body.data(using: .utf8) else {
            return .failure("LLM 返回无法解码")
        }

        do {
            let resp = try JSONDecoder().decode(ScenarioDerivationResponse.self, from: data)
            let scenarios = Array(resp.toScenarios().prefix(3))
            if scenarios.isEmpty {
                return .failure("LLM 没能生成有效场景，再试一次？")
            }
            return .success(scenarios)
        } catch {
            // Surface enough of the body to debug in TestFlight without
            // leaking the whole reply — first 200 chars is plenty.
            let head = body.prefix(200)
            return .failure("场景 JSON 解析失败 · head=\(head)")
        }
    }

    // MARK: - helpers

    /// Compress the analysis subtitles into ≤12 cue lines for the prompt.
    /// We pick the FIRST 6 and the MIDDLE 6 so the LLM gets both opening
    /// context + a glimpse of the body — fully concatenating a 10-min
    /// video's subtitles would blow the prompt budget for no extra signal.
    static func subtitleSummary(_ cues: [Cue]) -> String {
        guard !cues.isEmpty else { return "(无字幕信息)" }

        let count = cues.count
        let picks: [Cue]
        if count <= 12 {
            picks = cues
        } else {
            let opening = Array(cues.prefix(6))
            let midStart = max(6, count / 2 - 3)
            let middle = Array(cues[midStart..<min(midStart + 6, count)])
            picks = opening + middle
        }

        return picks.map { c in
            let en = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let zh = c.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if zh.isEmpty { return "- \(en)" }
            return "- \(en) ／ \(zh)"
        }.joined(separator: "\n")
    }

    /// Strip ```json ... ``` or ``` ... ``` fences the LLM occasionally
    /// adds despite the prompt asking for raw JSON. Returns the inner body
    /// when fenced; original string otherwise.
    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        // Drop the first fence line (``` or ```json).
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...])
        }
        // Drop trailing fence.
        if let lastFence = t.range(of: "```", options: .backwards) {
            t = String(t[..<lastFence.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ultimate fallback so the tab still has something to render when the
/// LLM is unreachable. One generic scenario; user can still press play.
extension RoleplayScenarioClient {
    static func stockFallback(videoTitle: String) -> RoleplayScenario {
        RoleplayScenario(
            id: UUID(),
            title: "随便聊聊这个视频",
            setup: "You and a friend just watched this video together. Discuss what you saw.",
            userRole: "viewer",
            agentRole: "friend",
            difficulty: 1,
            vocabHints: []
        )
    }
}
