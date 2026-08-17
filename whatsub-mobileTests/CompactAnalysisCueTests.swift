import XCTest
@testable import whatsub_mobile

final class CompactAnalysisCueTests: XCTestCase {
    private let usage = "表示补回落下的进度，常用于工作、学习或消息积压后追赶任务进度的自然交流语境。"

    func testRebuildsCueFromImmutableSource() throws {
        let source = Cue(index: 7, time: 12.3, endTime: 14.2, text: "I need to catch up")
        let output: [String: Any] = [
            "i": 7,
            "zh": "我得赶上进度",
            "p": [["catch up", "赶上进度", usage]],
            "text": "model text must be ignored",
            "time": 999,
        ]

        let result = try CompactAnalysisCue.validate(output, requested: [7: source])
        let accepted = CompactHighlightBudget(limit: 10).apply(to: result)

        XCTAssertEqual(accepted.cue.text, source.text)
        XCTAssertEqual(accepted.cue.time, source.time)
        XCTAssertEqual(accepted.cue.endTime, source.endTime)
        XCTAssertEqual(accepted.cue.highlightWords, ["catch up"])
    }

    func testMalformedAnnotationKeepsTranslationForRepair() throws {
        let source = Cue(index: 7, time: 0, endTime: 1, text: "I need to catch up")
        let result = try CompactAnalysisCue.validate([
            "i": 7,
            "zh": "我得赶上进度",
            "p": [["one two three four five", "赶上进度", "太短"]],
        ], requested: [7: source])

        XCTAssertEqual(result.cue.translation, "我得赶上进度")
        XCTAssertFalse(result.cue.isKeyPoint)
        XCTAssertTrue(result.needsAnnotationRepair)
    }

    func testRejectsUnknownIndexAndBlankTranslation() {
        let source = Cue(index: 7, time: 0, endTime: 1, text: "hello")
        XCTAssertThrowsError(try CompactAnalysisCue.validate(
            ["i": 8, "zh": "你好", "p": []], requested: [7: source]
        ))
        XCTAssertThrowsError(try CompactAnalysisCue.validate(
            ["i": 7, "zh": "  ", "p": []], requested: [7: source]
        ))
    }

    func testHighlightCapacityAndSharedBudget() throws {
        XCTAssertEqual(CompactAnalysisCue.capacity(for: 50), 10)
        XCTAssertEqual(CompactAnalysisCue.capacity(for: 13), 3)
        let budget = CompactHighlightBudget(limit: 10)
        for index in 0..<11 {
            let text = "catch up \(index)"
            let source = Cue(index: index, time: 0, endTime: 1, text: text)
            let result = try CompactAnalysisCue.validate([
                "i": index,
                "zh": "赶上进度 \(index)",
                "p": [["catch up", "赶上进度", usage]],
            ], requested: [index: source])
            let accepted = budget.apply(to: result)
            XCTAssertEqual(accepted.cue.isKeyPoint, index < 10)
        }
        XCTAssertEqual(budget.remaining, 0)
    }
}
