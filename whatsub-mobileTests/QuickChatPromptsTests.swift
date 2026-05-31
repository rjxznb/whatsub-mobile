import XCTest
@testable import whatsub_mobile

final class QuickChatPromptsTests: XCTestCase {

    private func phrase(_ raw: String, mean: String?, usage: String?, tags: [String] = []) -> SessionPhrase {
        SessionPhrase(phraseNormalized: raw, phraseRaw: raw, meaningZh: mean,
                      usageNote: usage, contextSentence: "ctx",
                      sourceKind: "webpage", sourceURL: "", sourceTimestampSec: nil,
                      tags: tags)
    }

    func testPromptContainsAllPhrasesWithMeaning() {
        let p = QuickChatPrompts.systemPrompt(
            phrases: [phrase("sort it out", mean: "解决", usage: "口语")],
            suggestedTag: nil
        )
        XCTAssertTrue(p.contains("sort it out"))
        XCTAssertTrue(p.contains("解决"))
        XCTAssertTrue(p.contains("口语"))
    }

    func testPromptIncludesScenarioHintWhenTagProvided() {
        let p = QuickChatPrompts.systemPrompt(
            phrases: [phrase("a", mean: "x", usage: nil)],
            suggestedTag: "餐厅点餐"
        )
        XCTAssertTrue(p.contains("餐厅点餐"))
    }

    func testPromptAsksLLMToInventSceneWhenNoTag() {
        let p = QuickChatPrompts.systemPrompt(
            phrases: [phrase("a", mean: "x", usage: nil)],
            suggestedTag: nil
        )
        XCTAssertTrue(p.contains("自行") || p.contains("自己"))
    }

    func testPromptDeclaresVerdictSentinelFormat() {
        let p = QuickChatPrompts.systemPrompt(phrases: [phrase("a", mean: "x", usage: nil)],
                                              suggestedTag: nil)
        XCTAssertTrue(p.contains("<<<VERDICT>>>"))
        XCTAssertTrue(p.contains("<<<END>>>"))
    }

    func testPromptForbidsRoleBreakAndTurn5Praise() {
        let p = QuickChatPrompts.systemPrompt(phrases: [phrase("a", mean: "x", usage: nil)],
                                              suggestedTag: nil)
        XCTAssertTrue(p.contains("始终留在角色") || p.contains("留在角色"))
        XCTAssertTrue(p.contains("第 5 轮") || p.contains("第5轮"))
        XCTAssertTrue(p.contains("本轮") || p.contains("仅本轮"))
    }

    func testPromptForbidsMarkdownAndTagPrefixes() {
        let p = QuickChatPrompts.systemPrompt(phrases: [phrase("a", mean: "x", usage: nil)],
                                              suggestedTag: nil)
        XCTAssertTrue(p.contains("禁止使用 markdown") || p.contains("禁止 markdown"))
        XCTAssertTrue(p.contains("<assistant>") && p.contains("不要"),
                      "must explicitly forbid the <assistant> literal prefix LLM was emitting")
    }

    func testPromptIncludesAllThreePhrasesInOrder() {
        let phrases = [
            phrase("bouncing off the walls", mean: "兴奋", usage: "口语"),
            phrase("sort it out", mean: "解决", usage: "口语；语序 sort it out"),
            phrase("fair enough", mean: "有道理", usage: "口语回应"),
        ]
        let p = QuickChatPrompts.systemPrompt(phrases: phrases, suggestedTag: nil)
        let idxA = p.range(of: "bouncing off the walls")!.lowerBound
        let idxB = p.range(of: "sort it out")!.lowerBound
        let idxC = p.range(of: "fair enough")!.lowerBound
        XCTAssertTrue(idxA < idxB && idxB < idxC, "phrase order is preserved")
    }
}
