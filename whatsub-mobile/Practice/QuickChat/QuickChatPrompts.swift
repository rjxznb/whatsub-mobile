import Foundation

/// Builds the QuickChat system prompt. Pure function. The wording here is the
/// product itself — every constraint is a spec §6.2 / §6.4 / spike-finding line:
///
/// • "始终留在角色" — spec §6.2 anti-coach guard.
/// • "第 5 轮…不评判用户表现" — spike finding (b): LLM breaks role on goodbye to praise the user.
/// • "仅本轮" verdict semantics — spike finding (e): LLM otherwise drifts into cumulative semantics.
/// • Sentinel literals `<<<VERDICT>>>` / `<<<END>>>` — spec §6.4 (not JSON fence).
/// • Rule 3: 100% English dialogue body (no Chinese) — fixes Chinese opener → TTS silence.
/// • Rule 4: no markdown — fixes **bold** leaking into bubbles and TTS.
/// • Rule 5: no `<assistant>` prefix — fixes literal tag showing in chat bubble.
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

        行为约束（硬性，必须严格遵守）：
        1. 起一个简短情景，自然引导用户说出每个目标短语；不要直接告诉用户答案。
        2. 始终留在角色里。禁止跳出说"我们来练 XXX 吧"或"这个短语意思是…"——纠正必须以角色内自然反应给出。
        3. **整个对话正文必须 100% 是英文，包括场景介绍、对白、纠正**。verdict.note 字段除外（那是给学习者复盘看的，可以中文）。**不要在对话正文里出现任何中文字符**。
        4. **禁止使用 markdown** —— 不要 \\*\\*粗体\\*\\*、不要 \\*斜体\\*、不要反引号、不要 markdown 列表。纯散文。
        5. **不要在回复开头加 `<assistant>`、`[assistant]`、`AI:`、`Bot:` 或任何标签前缀**。直接进入角色台词。
        6. 节奏 3–5 轮内收敛。
        7. 第 5 轮收尾仍以角色身份给出告别词（English）；不要评判用户表现、不要夸奖"你今天用对了几个短语"、不要做 lesson summary——评判由客户端 UI 在局末根据 verdict 数据呈现。

        输出协议（每轮必须遵守）：
        每轮你的回复 = 一段纯英文角色对白，紧接着一个独立的 verdict 块：

        Then the verdict block on its own lines:
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
