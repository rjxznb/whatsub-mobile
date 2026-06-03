import Foundation

/// Two prompts that drive the 角色扮演 tab:
///
/// 1. `scenePrompt(videoTitle:subtitleSummary:corpusPhrases:)` — fed to a
///    one-shot `chat()` call. Returns 1-3 scene cards anchored to the video.
/// 2. `turnSystemPrompt(scenario:)` — system prompt for the per-turn
///    `ConversationEngine`. Reuses the same `<<<VERDICT>>>` / `<<<END>>>`
///    sentinel as QuickChat so `VerdictParser` works unchanged — that's the
///    bridge that lets us write per-phrase mastery into the same
///    `ProductionProgressStore` the dialog practice tab feeds.
///
/// Why two prompts (vs. desktop's three — scene derivation, per-turn,
/// post-session report)? The desktop "report" prompt builds the forensic
/// view + writes ErrorEvents into a LearnerProfile. We chose lighter
/// persistence on iOS (per the design check earlier today) — the per-turn
/// verdict block carries enough signal to feed ProductionProgressStore;
/// no third LLM round is needed.
enum RoleplayPrompts {

    // MARK: - 1. Scene derivation (one-shot call)

    /// Build the scene-derivation prompt. The LLM should return a strict
    /// JSON envelope; `ScenarioDerivationResponse` decodes it.
    ///
    /// `subtitleSummary` is expected to be a short bullet of what the video
    /// is about (caller decides — usually the first ~12 cue translations
    /// joined with newlines, which gives the LLM enough to anchor a scene).
    ///
    /// `corpusPhrases` are the user's own collected phrases for this video.
    /// They're surfaced as a hint so the LLM picks scenes that REQUIRE
    /// those phrases — that way the session doubles as practice.
    static func scenePrompt(
        videoTitle: String,
        subtitleSummary: String,
        corpusPhrases: [String]
    ) -> [ChatMessage] {
        let phraseHint: String
        if corpusPhrases.isEmpty {
            phraseHint = "用户没有针对这个视频收藏短语，所以你可以自由选取最自然的 3-5 个 English phrases。"
        } else {
            let list = corpusPhrases.prefix(20).joined(separator: ", ")
            phraseHint = "用户已经针对这个视频收藏了下面这些英文短语 —— 请挑选能 naturally require 它们的场景，并把它们放进 vocabHints：\n\(list)"
        }

        let system = """
        你是一名英文口语陪练课程设计师。根据一段视频的内容 + 用户的目标短语，生成 1-3 个 short roleplay scenarios 让用户跟 AI 用英文对练。

        硬约束：
        - **只输出 JSON**，不要任何前后缀文字、不要 markdown 代码围栏。
        - 每个 scenario 必须锚定视频里的 setting / topic / characters；不要做和视频无关的通用场景。
        - title 用 8-14 字的简短中文，形如 "你当旅客我当海关"、"你点单我当店员"。
        - setup 是一句 English（25 字以内），描述场景。
        - userRole / agentRole 用 2-6 字的简洁角色名（中英皆可，保持简短）。
        - difficulty: 1=A2, 2=B1, 3=B2。结合视频原文难度判断；不确定就选 2。
        - vocabHints: 3-5 个 English phrases，全部小写、保留 phrasal 完整形态（"figure it out" 而非 "figure"）。
        - 不要给同一个视频生成 3 个相似场景；如果只有一个明显合适的，给 1 个就行。

        输出格式（exactly）：
        {
          "scenarios": [
            { "title": "...", "setup": "...", "userRole": "...",
              "agentRole": "...", "difficulty": 1, "vocabHints": ["...", "..."] }
          ]
        }
        """

        let user = """
        视频标题：\(videoTitle)

        视频要点摘要：
        \(subtitleSummary)

        \(phraseHint)

        现在请输出 JSON。
        """

        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }

    // MARK: - 2. Per-turn system prompt (for ConversationEngine)

    /// Per-turn prompt for the orb session. Mirrors `QuickChatPrompts.systemPrompt`
    /// at the structural level — same dialog + `<<<VERDICT>>>` sentinel, same
    /// hard rules about staying in character + 100% English body — but the
    /// task is "play this role in this scene" rather than "drill these phrases".
    ///
    /// `vocabHints` (the scenario's hint list) keys the verdict block, so the
    /// existing VerdictParser routes per-phrase results into the same
    /// ProductionProgressStore the practice tab uses.
    static func turnSystemPrompt(scenario: RoleplayScenario, maxTurns: Int) -> String {
        let hints = scenario.vocabHints
        let hintLines = hints.isEmpty
            ? "（这一局没有指定 vocab hints，让对话自然流动，verdicts 数组留空。）"
            : hints.map { "- \"\($0)\"" }.joined(separator: "\n")

        let verdictTemplate: String
        if hints.isEmpty {
            verdictTemplate = "{\"verdicts\":[]}"
        } else {
            let entries = hints.map {
                "  {\"phrase\":\"\($0)\",\"attempted\":<bool>,\"correct\":<bool>,\"note\":\"<纠正或空>\"}"
            }.joined(separator: ",\n")
            verdictTemplate = """
            {"verdicts":[
            \(entries)
            ]}
            """
        }

        return """
        You are playing the role of "\(scenario.agentRole)". The Chinese English-learner
        in front of you is playing "\(scenario.userRole)".

        Scene: \(scenario.setup)

        行为约束（硬性，必须严格遵守）：
        1. 始终留在 "\(scenario.agentRole)" 这个角色里。禁止跳出说"我们来练 XXX"、"这个短语意思是…"——
           纠正必须以角色内自然反应给出（"Sorry, you mean ___, right?"）。
        2. **整个对话正文必须 100% 是英文**，包括场景开场白、对白、纠正。verdict.note 字段除外
           （那是给学习者复盘看的，可以中文）。不要在对话正文里出现任何中文字符。
        3. **禁止使用 markdown** —— 不要 \\*\\*粗体\\*\\*、不要 \\*斜体\\*、不要反引号、不要列表。纯散文。
        4. **不要在回复开头加 `<assistant>`、`[assistant]`、`AI:`、`Bot:` 或任何标签前缀**。直接进入角色台词。
        5. 第一轮请用 1-2 句英文开场，把场景立起来（既建立角色身份也给用户回应空间），然后等用户回话。
        6. 每轮 1-3 句英文 conversation 即可，节奏自然。整局 \(maxTurns) 轮内收敛。
        7. 最后一轮以角色身份给一个 natural goodbye；不要总结学习表现、不要夸奖"你这一局表达得不错"
           ——评判由客户端 UI 根据 verdict 数据呈现。

        本场景预期会用到的目标短语（vocab hints）：
        \(hintLines)

        输出协议（每轮必须遵守）：
        每轮你的回复 = 一段纯英文角色对白，紧接着一个独立的 verdict 块：

        <<<VERDICT>>>
        \(verdictTemplate)
        <<<END>>>

        verdicts 必须包含上面列出的 \(hints.count) 个 vocab hints（数组长度与列表完全一致）。
        - `attempted` 指**仅本轮**用户最近一句话里有没有尝试使用该短语；不要把之前轮次的成功带进来。
        - `correct` 指尝试且 grammar/搭配/语境都正确。
        - `note` 用中文写一句简短纠正，没有错就留空字符串。
        """
    }
}
