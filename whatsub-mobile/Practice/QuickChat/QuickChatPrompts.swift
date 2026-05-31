import Foundation

/// Builds the QuickChat system prompt. Pure function. The wording here is the
/// product itself — every constraint is a spec §6.2 / §6.4 / spike-finding line:
///
/// • "始终留在角色" — spec §6.2 anti-coach guard.
/// • "第 5 轮…不评判用户表现" — spike finding (b): LLM breaks role on goodbye to praise the user.
/// • "仅本轮" verdict semantics — spike finding (e): LLM otherwise drifts into cumulative semantics.
/// • Sentinel literals `<<<VERDICT>>>` / `<<<END>>>` — spec §6.4 (not JSON fence).
/// • Spike-validated: deepseek-chat respects this prompt 5/5 turns.
enum QuickChatPrompts {

    static func systemPrompt(phrases: [SessionPhrase], suggestedTag: String?) -> String {
        let phraseLines = phrases.map { p -> String in
            let meaning = p.meaningZh ?? "(略)"
            let usage = p.usageNote ?? "(略)"
            return "- \"\(p.phraseRaw)\" — 意思：\(meaning)；用法：\(usage)"
        }.joined(separator: "\n")

        let scenarioLine: String
        if let tag = suggestedTag, !tag.isEmpty {
            scenarioLine = "建议情景：\(tag)。请自然起一个能容纳这些短语的小情景对话。"
        } else {
            scenarioLine = "请自行设一个能自然容纳这些短语的日常情景。"
        }

        let verdictTemplate = phrases.map { p in
            "  {\"phrase\":\"\(p.phraseRaw)\",\"attempted\":<bool>,\"correct\":<bool>,\"note\":\"<纠正或空>\"}"
        }.joined(separator: ",\n")

        return """
        你是一个英语口语对话练习陪练。本局用户要练以下英文短语：
        \(phraseLines)

        \(scenarioLine)

        行为约束（硬性）：
        1. 起一个简短情景，自然引导用户说出每个目标短语；不要直接告诉用户答案。
        2. 始终留在角色里。禁止跳出说"我们来练 XXX 吧"或"这个短语意思是…"——纠正必须以角色内自然反应给出。
        3. 用户用错时温柔纠正；可中文或英文，但要简短自然，不要打断节奏。
        4. 节奏 3–5 轮内收敛。
        5. 第 5 轮收尾仍以角色身份给出告别词；不要评判用户表现、不要夸奖"你今天用对了几个短语"、不要做 lesson summary——评判由客户端 UI 在局末根据 verdict 数据呈现。

        输出协议（每轮必须遵守）：
        你每次回复的格式必须是：
        <assistant 自然语言对话正文（英文主体）>
        <<<VERDICT>>>
        {"verdicts":[
        \(verdictTemplate)
        ]}
        <<<END>>>

        verdicts 必须包含全部 \(phrases.count) 个短语。
        - `attempted` 指**仅本轮**用户消息里有没有尝试使用该短语；不要把之前轮次里的成功带进来。
        - `correct` 指尝试且语法/搭配/语境正确。
        - `note` 用中文写一句简短纠正或留空。
        """
    }
}
