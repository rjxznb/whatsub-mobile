import XCTest
@testable import whatsub_mobile

final class AnalysisDecodeTests: XCTestCase {
    func testDecodeAnalysisWithCues() throws {
        let json = #"""
        {"subtitles":[
          {"time":0.0,"endTime":2.5,"text":"Hello there.","translation":"你好。","isKeyPoint":false,"highlightWords":["Hello"],"keyNotes":{"Hello":"问候"},"highlightTranslations":{"Hello":"你好"}},
          {"time":2.5,"endTime":5.0,"text":"Save up money.","translation":"攒钱。","isKeyPoint":true,"highlightWords":["Save up"],"keyNotes":{},"highlightTranslations":{}}
        ],"keyPhrases":[{"expression":"save up","meaningZh":"攒钱","usage":"存钱以备将来"}]}
        """#.data(using: .utf8)!
        let a = try JSONDecoder().decode(AnalysisJson.self, from: json)
        XCTAssertEqual(a.subtitles.count, 2)
        XCTAssertEqual(a.subtitles[0].index, 0)
        XCTAssertEqual(a.subtitles[1].index, 1)
        XCTAssertEqual(a.subtitles[0].text, "Hello there.")
        XCTAssertEqual(a.subtitles[0].translation, "你好。")
        XCTAssertEqual(a.subtitles[0].highlightWords, ["Hello"])
        XCTAssertEqual(a.subtitles[0].keyNotes["Hello"], "问候")
        XCTAssertEqual(a.keyPhrases.first?.expression, "save up")
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        let json = #"{"subtitles":[{"time":1,"endTime":2,"text":"Hi","translation":"嗨"}],"keyPhrases":[]}"#.data(using: .utf8)!
        let a = try JSONDecoder().decode(AnalysisJson.self, from: json)
        XCTAssertEqual(a.subtitles[0].highlightWords, [])
        XCTAssertFalse(a.subtitles[0].isKeyPoint)
    }
}
