import XCTest
@testable import whatsub_mobile

final class AssistantTextSanitizerTests: XCTestCase {

    func testStripsLeadingAssistantTag() {
        XCTAssertEqual(AssistantTextSanitizer.sanitize("<assistant>Hey there"), "Hey there")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("<Assistant>Hey there"), "Hey there")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("<assistant 自然语言对话正文>Hey there"), "Hey there")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("[assistant] Hey there"), "Hey there")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("Assistant: Hey there"), "Hey there")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("AI: Hey there"), "Hey there")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("   <assistant>Hey"), "Hey")
    }

    func testKeepsContentWithoutTag() {
        XCTAssertEqual(AssistantTextSanitizer.sanitize("Hello there"), "Hello there")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("Hi, what's up?"), "Hi, what's up?")
    }

    func testStripsBoldMarkdown() {
        XCTAssertEqual(AssistantTextSanitizer.sanitize("Look **under the hood**"), "Look under the hood")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("**comes in** and **goes out**"),
                       "comes in and goes out")
    }

    func testStripsItalicMarkdown() {
        XCTAssertEqual(AssistantTextSanitizer.sanitize("Hey *there*"), "Hey there")
        XCTAssertEqual(AssistantTextSanitizer.sanitize("Try _this_"), "Try this")
    }

    func testStripsBacktickCode() {
        XCTAssertEqual(AssistantTextSanitizer.sanitize("Run `sort it out`"), "Run sort it out")
    }

    func testCombinedTagAndMarkdown() {
        XCTAssertEqual(
            AssistantTextSanitizer.sanitize("<assistant>Try **sort it out** and *fair enough*"),
            "Try sort it out and fair enough"
        )
    }

    func testDoesNotStripMidWordAsterisks() {
        // Asterisks not paired → leave alone (don't strip stray `*`).
        XCTAssertEqual(AssistantTextSanitizer.sanitize("two * three = six"), "two * three = six")
    }

    func testNonGreedyMatchingAcrossMultiplePairs() {
        XCTAssertEqual(AssistantTextSanitizer.sanitize("**a** middle **b**"), "a middle b")
    }
}
