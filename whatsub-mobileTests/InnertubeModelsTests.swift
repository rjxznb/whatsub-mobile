import XCTest
@testable import whatsub_mobile

final class InnertubeModelsTests: XCTestCase {

    private func track(language: String, kind: String? = nil,
                       baseUrl: String = "https://example.com") -> CaptionTrack {
        CaptionTrack(baseUrl: baseUrl, languageCode: language, kind: kind)
    }

    func testPicksEnglishManualOverASR() {
        let picked = pickBestEnglishCaptionTrack([
            track(language: "en", kind: "asr",
                  baseUrl: "https://example.com/asr"),
            track(language: "en", kind: nil,
                  baseUrl: "https://example.com/manual"),
        ])
        XCTAssertEqual(picked?.baseUrl, "https://example.com/manual",
                       "manual track must win over ASR even when ASR comes first")
    }

    func testFallsBackToASRWhenNoManual() {
        let picked = pickBestEnglishCaptionTrack([
            track(language: "en", kind: "asr"),
        ])
        XCTAssertEqual(picked?.kind, "asr")
    }

    func testReturnsNilWhenNoEnglish() {
        let picked = pickBestEnglishCaptionTrack([
            track(language: "es"),
            track(language: "fr"),
            track(language: "ja", kind: "asr"),
        ])
        XCTAssertNil(picked)
    }

    func testMatchesEnglishVariants() {
        // YouTube sometimes returns "en-US" / "en-GB" — our check uses
        // hasPrefix("en") so these should all count as English.
        XCTAssertNotNil(pickBestEnglishCaptionTrack([track(language: "en-US")]))
        XCTAssertNotNil(pickBestEnglishCaptionTrack([track(language: "en-GB")]))
    }

    func testDecodesPlayerResponse() throws {
        let json = #"""
        {
          "playabilityStatus": { "status": "OK" },
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                { "baseUrl": "https://example.com/t1", "languageCode": "en-US" },
                { "baseUrl": "https://example.com/t2", "languageCode": "en", "kind": "asr" }
              ]
            }
          }
        }
        """#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PlayerResponse.self, from: json)
        XCTAssertEqual(resp.playabilityStatus.status, "OK")
        XCTAssertEqual(resp.captions?.playerCaptionsTracklistRenderer?
                            .captionTracks.count, 2)
    }

    func testDecodesWhenCaptionsAbsent() throws {
        // Videos without any captions return a player response with no
        // `captions` key at all. The decode must succeed; the extractor
        // turns the missing captions into CaptionError.noCaptions.
        let json = #"""
        { "playabilityStatus": { "status": "OK" } }
        """#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PlayerResponse.self, from: json)
        XCTAssertNil(resp.captions)
    }
}
