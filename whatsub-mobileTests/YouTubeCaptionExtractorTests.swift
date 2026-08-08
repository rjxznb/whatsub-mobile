import XCTest
@testable import whatsub_mobile

final class YouTubeCaptionExtractorTests: XCTestCase {

    private var tempDir: URL!
    private var cache: CaptionCache!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("YTExtractorTests-\(UUID().uuidString)",
                                    isDirectory: true)
        cache = CaptionCache(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Build a JSON-format timedtext (json3) body matching what the
    /// extractor's parseTimedtextJson3 dependency expects.
    private func makeTimedtextJson3() -> Data {
        let json = """
        {"events":[
          {"tStartMs":0,"dDurationMs":1500,"segs":[{"utf8":"Hello"}]},
          {"tStartMs":1500,"dDurationMs":1500,"segs":[{"utf8":"World"}]}
        ]}
        """
        return json.data(using: .utf8)!
    }

    private func ok(_ data: Data) -> (Data, URLResponse) {
        let resp = HTTPURLResponse(url: URL(string: "https://x")!,
                                   statusCode: 200,
                                   httpVersion: nil,
                                   headerFields: nil)!
        return (data, resp)
    }

    private func status(_ code: Int) -> (Data, URLResponse) {
        let resp = HTTPURLResponse(url: URL(string: "https://x")!,
                                   statusCode: code,
                                   httpVersion: nil,
                                   headerFields: nil)!
        return (Data(), resp)
    }

    private func downgradeCacheToLegacy(videoId: String) throws {
        let path = tempDir.appendingPathComponent("\(videoId).json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        )
        object["version"] = 1
        object.removeValue(forKey: "durationSec")
        try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
    }

    // MARK: - Happy path

    func testExtractHappyPath() async throws {
        let playerJSON = """
        {
          "playabilityStatus": {"status": "OK"},
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {"baseUrl": "https://yt.example/timedtext?v=abc",
                 "languageCode": "en"}
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let timedtextData = makeTimedtextJson3()
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { req in
            calls += 1
            switch calls {
            case 1:
                XCTAssertEqual(req.httpMethod, "POST")
                XCTAssertTrue(req.url?.absoluteString
                              .contains("youtubei/v1/player") ?? false)
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-YouTube-Client-Name"),
                               "28")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-YouTube-Client-Version"),
                               "1.65.10")
                XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"),
                               "application/json")
                return self.ok(playerJSON)
            case 2:
                XCTAssertEqual(req.httpMethod, "GET")
                XCTAssertTrue(req.url?.absoluteString
                              .contains("yt.example/timedtext") ?? false)
                XCTAssertTrue(req.url?.absoluteString
                              .contains("fmt=json3") ?? false)
                return self.ok(timedtextData)
            default:
                XCTFail("unexpected request")
                return self.status(500)
            }
        }
        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "abc",
            cache: cache,
            fetcher: fetcher
        )
        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(result.cues[0].text, "Hello")
        XCTAssertEqual(result.cues[1].text, "World")
        XCTAssertNil(result.durationSec)
    }

    func testExtractReturnsInnertubeDuration() async throws {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "videoDetails":{"lengthSeconds":"1201"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return calls == 1 ? self.ok(playerJSON) : self.ok(self.makeTimedtextJson3())
        }

        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "duration", cache: cache, fetcher: fetcher
        )

        XCTAssertEqual(result.durationSec, 1201)
        XCTAssertEqual(result.cues.count, 2)
    }

    func testExtractRejectsNonPositiveInnertubeDuration() async throws {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "videoDetails":{"lengthSeconds":"0"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return calls == 1 ? self.ok(playerJSON) : self.ok(self.makeTimedtextJson3())
        }

        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "zero-duration", cache: cache, fetcher: fetcher
        )

        XCTAssertNil(result.durationSec)
    }

    // MARK: - Cache

    func testReturnsCachedOnHit() async throws {
        cache.set(
            "cached_id",
            result: CaptionExtractionResult(
                cues: [Cue(index: 0, time: 0, endTime: 1, text: "From cache")],
                durationSec: 42
            )
        )
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return self.status(500)
        }
        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "cached_id",
            cache: cache,
            fetcher: fetcher
        )
        XCTAssertEqual(calls, 0, "fetcher must not run when cache hits")
        XCTAssertEqual(result.cues.count, 1)
        XCTAssertEqual(result.cues[0].text, "From cache")
        XCTAssertEqual(result.durationSec, 42)
    }

    func testLegacyCacheRefreshesOnlyPlayerMetadataAndUpgradesCache() async throws {
        cache.set(
            "legacy_id",
            result: CaptionExtractionResult(
                cues: [Cue(index: 0, time: 0, endTime: 1, text: "Legacy cue")],
                durationSec: nil
            )
        )
        try downgradeCacheToLegacy(videoId: "legacy_id")
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "videoDetails":{"lengthSeconds":"321"}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            return self.ok(playerJSON)
        }

        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "legacy_id", cache: cache, fetcher: fetcher
        )

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.cues.first?.text, "Legacy cue")
        XCTAssertEqual(result.durationSec, 321)
        XCTAssertEqual(cache.get("legacy_id")?.needsMetadataRefresh, false)
    }

    func testLegacyCacheSurvivesMetadataNetworkFailureAndRemainsRefreshable() async throws {
        cache.set(
            "legacy_offline",
            result: CaptionExtractionResult(
                cues: [Cue(index: 0, time: 0, endTime: 1, text: "Offline cue")],
                durationSec: nil
            )
        )
        try downgradeCacheToLegacy(videoId: "legacy_offline")
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "legacy_offline", cache: cache, fetcher: fetcher
        )

        XCTAssertEqual(result.cues.first?.text, "Offline cue")
        XCTAssertNil(result.durationSec)
        XCTAssertEqual(cache.get("legacy_offline")?.needsMetadataRefresh, true)
    }

    func testLegacyCacheWithMissingDurationUpgradesOnce() async throws {
        cache.set(
            "legacy_no_duration",
            result: CaptionExtractionResult(
                cues: [Cue(index: 0, time: 0, endTime: 1, text: "Cached cue")],
                durationSec: nil
            )
        )
        try downgradeCacheToLegacy(videoId: "legacy_no_duration")
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return self.ok(playerJSON)
        }

        let first = try await YouTubeCaptionExtractor.extract(
            videoId: "legacy_no_duration", cache: cache, fetcher: fetcher
        )
        let second = try await YouTubeCaptionExtractor.extract(
            videoId: "legacy_no_duration", cache: cache, fetcher: fetcher
        )

        XCTAssertNil(first.durationSec)
        XCTAssertNil(second.durationSec)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cache.get("legacy_no_duration")?.needsMetadataRefresh, false)
    }

    func testLegacyCacheSurvivesPlaybackFailureAndRemainsRefreshable() async throws {
        cache.set(
            "legacy_unplayable",
            result: CaptionExtractionResult(
                cues: [Cue(index: 0, time: 0, endTime: 1, text: "Cached cue")],
                durationSec: nil
            )
        )
        try downgradeCacheToLegacy(videoId: "legacy_unplayable")
        let playerJSON = """
        {"playabilityStatus":{"status":"UNPLAYABLE"}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }

        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "legacy_unplayable", cache: cache, fetcher: fetcher
        )

        XCTAssertEqual(result.cues.first?.text, "Cached cue")
        XCTAssertNil(result.durationSec)
        XCTAssertEqual(cache.get("legacy_unplayable")?.needsMetadataRefresh, true)
    }

    func testWritesCacheOnSuccess() async throws {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return calls == 1 ? self.ok(playerJSON) : self.ok(self.makeTimedtextJson3())
        }
        _ = try await YouTubeCaptionExtractor.extract(
            videoId: "writeback",
            cache: cache,
            fetcher: fetcher
        )
        XCTAssertNotNil(cache.get("writeback"),
                        "successful extract must populate the cache")
    }

    // MARK: - Failure cases

    func testThrowsRequiresLoginForAgeGate() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"LOGIN_REQUIRED"}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "gated", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.requiresLogin = error else {
                XCTFail("expected .requiresLogin, got \(error)"); return
            }
        }
    }

    func testThrowsVideoUnavailableForUnplayable() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"UNPLAYABLE"}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.videoUnavailable = error else {
                XCTFail("expected .videoUnavailable, got \(error)"); return
            }
        }
    }

    func testThrowsNoCaptions() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.noCaptions = error else {
                XCTFail("expected .noCaptions, got \(error)"); return
            }
        }
    }

    func testThrowsNoEnglishCaptions() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://x","languageCode":"es"}
         ]}}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.noEnglishCaptions = error else {
                XCTFail("expected .noEnglishCaptions, got \(error)"); return
            }
        }
    }

    func testThrowsHTTPOnNon200Player() async {
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.status(503) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.http(let status) = error else {
                XCTFail("expected .http, got \(error)"); return
            }
            XCTAssertEqual(status, 503)
        }
    }

    func testThrowsTimedtextFetchFailedOnNon200Timedtext() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return calls == 1 ? self.ok(playerJSON) : self.status(404)
        }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.timedtextFetchFailed(let status) = error else {
                XCTFail("expected .timedtextFetchFailed, got \(error)"); return
            }
            XCTAssertEqual(status, 404)
        }
    }

    func testThrowsNetworkOnURLError() async {
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            throw URLError(.notConnectedToInternet)
        }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.network = error else {
                XCTFail("expected .network, got \(error)"); return
            }
        }
    }

    // MARK: - Client fallback chain

    func testFallsBackToNextClientOnUnplayable() async throws {
        let unplayableJSON = """
        {"playabilityStatus":{"status":"UNPLAYABLE"}}
        """.data(using: .utf8)!
        let okJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var playerCalls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { req in
            if req.httpMethod == "POST" {
                playerCalls += 1
                // First client UNPLAYABLE → must try the next one.
                return playerCalls == 1 ? self.ok(unplayableJSON) : self.ok(okJSON)
            }
            return self.ok(self.makeTimedtextJson3())
        }
        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "fb", cache: cache, fetcher: fetcher
        )
        XCTAssertEqual(playerCalls, 2,
                       "should advance to second client after UNPLAYABLE")
        XCTAssertEqual(result.cues.count, 2)
    }

    func testFallsBackToNextClientOnHTTPError() async throws {
        let okJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var playerCalls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { req in
            if req.httpMethod == "POST" {
                playerCalls += 1
                // First client HTTP 400 → fallback chain must keep going
                // (the bug X_-Q1hOYeCo hit before the catch-and-continue
                // fix landed: IOS HTTP 400 was propagating out instead of
                // letting TVHTML5 take over).
                return playerCalls == 1 ? self.status(400) : self.ok(okJSON)
            }
            return self.ok(self.makeTimedtextJson3())
        }
        let result = try await YouTubeCaptionExtractor.extract(
            videoId: "fb-http", cache: cache, fetcher: fetcher
        )
        XCTAssertEqual(playerCalls, 2,
                       "should advance to next client after HTTP 400")
        XCTAssertEqual(result.cues.count, 2)
    }

    func testExhaustsAllClientsThenThrows() async {
        let unplayableJSON = """
        {"playabilityStatus":{"status":"UNPLAYABLE"}}
        """.data(using: .utf8)!
        var playerCalls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            playerCalls += 1
            return self.ok(unplayableJSON)
        }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.videoUnavailable = error else {
                XCTFail("expected .videoUnavailable, got \(error)"); return
            }
        }
        XCTAssertEqual(playerCalls, 4,
                       "must try every client in the fallback chain")
    }

    // MARK: - Progress events

    func testEmitsProgressEvents() async throws {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return calls == 1 ? self.ok(playerJSON) : self.ok(self.makeTimedtextJson3())
        }
        var events: [String] = []
        let collect: @MainActor (String) -> Void = { events.append($0) }
        _ = try await YouTubeCaptionExtractor.extract(
            videoId: "x", cache: cache, fetcher: fetcher, onProgress: collect
        )
        XCTAssertTrue(events.contains(where: { $0.contains("cache miss") }))
        XCTAssertTrue(events.contains(where: { $0.contains("POST youtubei") }))
        XCTAssertTrue(events.contains(where: { $0.contains("captionTracks") }))
        XCTAssertTrue(events.contains(where: { $0.contains("picked") }))
        XCTAssertTrue(events.contains(where: { $0.contains("parsed") }))
    }
}

// MARK: - Test helper

/// Async equivalent of XCTAssertThrowsError. Captures any thrown error
/// and routes it through `errorHandler` so tests can pattern-match the
/// CaptionError case.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected error, got success", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
