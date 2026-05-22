import XCTest
@testable import whatsub_mobile

final class CorpusDecodeTests: XCTestCase {
    func testBrowseSnakeCase() throws {
        let json = #"{"phrases":[{"phrase_normalized":"save up","phrase_raw":"save up","contribution_count":3,"first_seen_at":1,"last_seen_at":2,"meaning_zh":"攒钱","usage_note":"存钱","tags":["money"]}],"total":1}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(BrowseResponse.self, from: json)
        XCTAssertEqual(r.phrases.first?.phraseRaw, "save up")
        XCTAssertEqual(r.phrases.first?.meaningZh, "攒钱")
        XCTAssertEqual(r.phrases.first?.tags, ["money"])
    }

    func testMineCamelCaseWithSource() throws {
        let json = #"{"items":[{"phraseNormalized":"moe","phraseRaw":"MoE","meaningZh":"专家混合","usageNote":"用法","contextSentence":"... MoE ...","source":{"url":"https://x.com","kind":"webpage","title":"X"},"contributedAt":1779360308213,"tags":["AI"]}],"total":1}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(MineResponse.self, from: json)
        XCTAssertEqual(r.items.first?.phraseRaw, "MoE")
        XCTAssertEqual(r.items.first?.source.kind, "webpage")
        XCTAssertNil(r.items.first?.source.timestampSec)
        XCTAssertEqual(r.items.first?.contributedAt, 1779360308213)
    }

    func testLookupWithWrappedTagsAndYouTubeSource() throws {
        let json = #"""
        {"phrase":{"phrase_raw":"save up","meaning_zh":"攒钱","usage_note":"存钱","tags":{"list":["money"]}},
         "publicContributions":[],
         "personalContributions":[{"id":7,"phrase_normalized":"save up","context_sentence":"I save up.","source":{"kind":"youtube","url":"https://www.youtube.com/watch?v=abc12345678","timestampSec":42},"contributor_id":"u","contributed_at":99,"meaning_zh":null,"usage_note":null,"tags":[],"flagged":false,"flag_count":0,"hidden":false}]}
        """#.data(using: .utf8)!
        let r = try JSONDecoder().decode(LookupResponse.self, from: json)
        XCTAssertEqual(r.phrase.tags, ["money"])   // unwrapped from {list:[...]}
        let c = r.personalContributions.first!
        XCTAssertEqual(c.id, 7)
        XCTAssertEqual(c.source.kind, "youtube")
        XCTAssertEqual(c.source.timestampSec, 42)
        XCTAssertEqual(extractYouTubeID(c.source.url), "abc12345678")
    }
}
