import XCTest
@testable import whatsub_mobile

final class HighlightingTests: XCTestCase {
    func testNoHighlights() {
        let runs = splitForHighlights("hello world", highlights: [])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "hello world")
        XCTAssertFalse(runs[0].highlight)
    }

    func testSingleHighlight() {
        let runs = splitForHighlights("save up money now", highlights: ["save up"])
        XCTAssertEqual(runs.map(\.text), ["save up", " money now"])
        XCTAssertEqual(runs.map(\.highlight), [true, false])
    }

    func testMiddleHighlight() {
        let runs = splitForHighlights("I really need it", highlights: ["really need"])
        XCTAssertEqual(runs.map(\.text), ["I ", "really need", " it"])
        XCTAssertEqual(runs.map(\.highlight), [false, true, false])
    }

    func testNonOverlappingEarliestWins() {
        let runs = splitForHighlights("abcde", highlights: ["abc", "bcd"])
        XCTAssertEqual(runs.map(\.text), ["abc", "de"])
        XCTAssertEqual(runs.map(\.highlight), [true, false])
    }

    func testMissingHighlightIgnored() {
        let runs = splitForHighlights("hello", highlights: ["xyz"])
        XCTAssertEqual(runs.map(\.text), ["hello"])
        XCTAssertEqual(runs.map(\.highlight), [false])
    }
}
