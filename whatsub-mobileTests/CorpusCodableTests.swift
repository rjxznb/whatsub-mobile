import XCTest
@testable import whatsub_mobile

final class CorpusCodableTests: XCTestCase {
    private func decode<T: Decodable>(_ t: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testLookupResponseRoundTripsThroughOurEncoder() throws {
        // Server shape: tags wrapped as { list: [...] }.
        let serverJSON = """
        {"phrase":{"phrase_raw":"kick the bucket","meaning_zh":"翘辫子","usage_note":"口语","tags":{"list":["idiom","death"]}},
         "publicContributions":[{"id":1,"context_sentence":"He kicked the bucket.","source":{"kind":"youtube","url":"u","title":"t","timestampSec":1.5},"contributed_at":1000}],
         "personalContributions":[]}
        """
        let original = try decode(LookupResponse.self, serverJSON)
        // Encode with OUR encoder, then decode again — must survive.
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(LookupResponse.self, from: data)
        XCTAssertEqual(round.phrase.phraseRaw, "kick the bucket")
        XCTAssertEqual(round.phrase.meaningZh, "翘辫子")
        XCTAssertEqual(round.phrase.tags, ["idiom","death"])      // tags survive wrap/unwrap
        XCTAssertEqual(round.publicContributions.count, 1)
        XCTAssertEqual(round.publicContributions.first?.contextSentence, "He kicked the bucket.")
        XCTAssertEqual(round.publicContributions.first?.source.kind, "youtube")
    }

    func testBrowsePhraseRoundTrips() throws {
        let original = try decode(BrowsePhrase.self,
            #"{"phrase_normalized":"a","phrase_raw":"A","meaning_zh":"甲","usage_note":null,"tags":["x"]}"#)
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(BrowsePhrase.self, from: data)
        XCTAssertEqual(round.phraseNormalized, "a")
        XCTAssertEqual(round.phraseRaw, "A")
        XCTAssertEqual(round.meaningZh, "甲")
        XCTAssertEqual(round.tags, ["x"])
    }

    func testMineItemRoundTrips() throws {
        let original = try decode(MineItem.self,
            #"{"phraseNormalized":"a","phraseRaw":"A","meaningZh":"甲","usageNote":null,"contextSentence":"ctx","source":{"kind":"webpage","url":"u","title":null,"timestampSec":null},"contributedAt":42,"tags":["y"]}"#)
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(MineItem.self, from: data)
        XCTAssertEqual(round.phraseRaw, "A")
        XCTAssertEqual(round.contextSentence, "ctx")
        XCTAssertEqual(round.contributedAt, 42)
        XCTAssertEqual(round.tags, ["y"])
    }
}
