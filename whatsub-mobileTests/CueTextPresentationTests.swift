import XCTest
@testable import whatsub_mobile

final class CueTextPresentationTests: XCTestCase {
    func testNewlinesCannotReorderProductionCue() {
        let value = CueTextPresentation.make(
            text: "-They love you.\nWe love you. Welcome back.",
            highlights: ["Welcome back"]
        )
        XCTAssertEqual(value.plainText, "-They love you. We love you. Welcome back.")
        XCTAssertEqual(value.runs.map(\.text).joined(), value.plainText)
        XCTAssertEqual(value.highlightPhrase(id: 0), "Welcome back")
        XCTAssertFalse(value.plainText.contains("back ."))
    }

    func testSecondProductionCueKeepsImBeforeExcited() {
        let value = CueTextPresentation.make(
            text: "Congrats. July 4th.\nI'm excited about the premiere.",
            highlights: ["premiere"]
        )
        XCTAssertEqual(value.plainText, "Congrats. July 4th. I'm excited about the premiere.")
    }

    func testWhitespaceAcrossRunBoundariesCollapsesOnce() {
        let value = CueTextPresentation.make(text: "Use  catch up \n now!", highlights: ["catch up"])
        XCTAssertEqual(value.plainText, "Use catch up now!")
        XCTAssertEqual(value.highlightPhrase(id: 0), "catch up")
    }
}
