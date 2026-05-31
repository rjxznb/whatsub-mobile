import XCTest
@testable import whatsub_mobile

final class SentenceChunkerTests: XCTestCase {

    func testEmitsOnPeriodOrQuestionOrExclamation() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hello world."), ["Hello world."])
        XCTAssertEqual(c.feed("Are you ok?"), ["Are you ok?"])
        XCTAssertEqual(c.feed("Stop!"), ["Stop!"])
    }

    func testWaitsUntilTerminator() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hello "), [])
        XCTAssertEqual(c.feed("world"), [])
        XCTAssertEqual(c.feed("."), ["Hello world."])
    }

    func testMultipleSentencesInOneChunk() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hi. How are you? Fine."),
                       ["Hi.", "How are you?", "Fine."])
    }

    func testNewlineActsAsTerminator() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Line one\nLine two\n"), ["Line one", "Line two"])
    }

    func testFlushReturnsTrailingPartial() {
        var c = SentenceChunker()
        _ = c.feed("Hello ")
        XCTAssertEqual(c.flush(), ["Hello"])  // trimmed
        XCTAssertEqual(c.flush(), [])         // already flushed
    }
}
