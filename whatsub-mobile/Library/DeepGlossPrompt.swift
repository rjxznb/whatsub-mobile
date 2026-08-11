import Foundation

struct DeepGlossContext {
    let title: String
    let profile: VideoContextProfile
    let expression: String
    let quickTranslation: String?
    let quickNote: String?
    let cues: [Cue]
    let currentCueIndex: Int
}

struct DeepGlossPromptPayload {
    let messages: [ChatMessage]
    let includedCueIndexes: [Int]
}

enum DeepGlossExpression {
    private static let lowercaseLocale = Locale(identifier: "en_US_POSIX")

    static func normalize(_ expression: String) -> String {
        expression
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased(with: lowercaseLocale)
    }
}

enum DeepGlossPrompt {
    private static let maximumCueCount = 9
    private static let precedingCueCount = 4

    static func build(context: DeepGlossContext) -> DeepGlossPromptPayload {
        let window = cueWindow(
            cues: context.cues,
            currentCueIndex: context.currentCueIndex
        )
        let cueObjects: [[String: Any]] = window.map { cue in
            [
                "index": cue.index,
                "time": cue.time,
                "endTime": cue.endTime,
                "text": cue.text,
                "translation": cue.translation,
            ]
        }
        let profile: [String: Any] = [
            "theme": context.profile.theme,
            "participants": context.profile.participants,
            "setting": context.profile.setting,
            "tone": context.profile.tone,
            "culturalContext": context.profile.culturalContext,
            "recurringConcepts": context.profile.recurringConcepts,
        ]
        let currentCue = context.cues.indices.contains(context.currentCueIndex)
            ? context.cues[context.currentCueIndex]
            : window.first
        let userObject: [String: Any] = [
            "videoTitle": context.title,
            "contextProfile": profile,
            "expression": DeepGlossExpression.normalize(context.expression),
            "quickTranslation": context.quickTranslation ?? "",
            "quickNote": context.quickNote ?? "",
            "currentCueIndex": currentCue?.index ?? 0,
            "currentCueTimestamp": currentCue?.time ?? 0,
            "cues": cueObjects,
        ]
        let userData = try? JSONSerialization.data(
            withJSONObject: userObject,
            options: [.sortedKeys]
        )
        let userContent = userData.map { String(decoding: $0, as: UTF8.self) } ?? "{}"

        return DeepGlossPromptPayload(
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userContent),
            ],
            includedCueIndexes: window.map(\.index)
        )
    }

    private static func cueWindow(cues: [Cue], currentCueIndex: Int) -> ArraySlice<Cue> {
        guard !cues.isEmpty else { return cues[0..<0] }
        let current = min(max(0, currentCueIndex), cues.count - 1)
        let count = min(maximumCueCount, cues.count)
        let latestStart = cues.count - count
        let start = min(max(0, current - precedingCueCount), latestStart)
        return cues[start..<(start + count)]
    }

    private static let systemPrompt = """
    你是英语学习语境解读助手。只依据给定的视频语境、当前表达和最多九条完整字幕解释，不得假装看过未提供的字幕。
    只返回一个 JSON 对象，键必须且只能是：
    {"contextualMeaning":"中文","toneAndSubtext":"中文","slangOrIdiom":"中文或空字符串","culturalContext":"中文或空字符串","naturalAlternatives":["English"],"usageWarning":"中文或空字符串"}
    contextualMeaning 与 toneAndSubtext 必须基于给定证据；无法确认俚语、文化背景或使用警告时返回空字符串，禁止猜测。
    每个字符串最多 500 个字符，naturalAlternatives 最多 5 条，整个 JSON 不得超过 4 KB。
    不得添加分数、评级、百分比、排名、Markdown、代码围栏或任何额外字段。
    """
}
