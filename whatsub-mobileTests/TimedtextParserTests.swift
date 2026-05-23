import XCTest
@testable import whatsub_mobile

final class TimedtextParserTests: XCTestCase {
    func testParsesJson3Events() throws {
        let json = #"""
        {"events":[
          {"tStartMs":0,"dDurationMs":1500,"segs":[{"utf8":"Hello "},{"utf8":"there."}]},
          {"tStartMs":1500,"dDurationMs":2000,"segs":[{"utf8":"How are you?"}]},
          {"tStartMs":3500,"dDurationMs":1000,"segs":[{"utf8":"   "}]}
        ]}
        """#.data(using: .utf8)!
        let cues = parseTimedtextJson3(json)
        XCTAssertEqual(cues.count, 2) // blank-only event dropped
        XCTAssertEqual(cues[0].idx, 0)
        XCTAssertEqual(cues[0].text, "Hello there.")
        XCTAssertEqual(cues[0].time, 0.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 1.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "How are you?")
        XCTAssertEqual(cues[1].time, 1.5, accuracy: 0.001)
    }

    func testEmptyOrBadInput() {
        XCTAssertEqual(parseTimedtextJson3(Data("{}".utf8)).count, 0)
        XCTAssertEqual(parseTimedtextJson3(Data("not json".utf8)).count, 0)
    }
}
