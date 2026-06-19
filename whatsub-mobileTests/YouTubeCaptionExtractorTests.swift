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
                               "3")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-YouTube-Client-Version"),
                               "1.9")
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
        let cues = try await YouTubeCaptionExtractor.extract(
            videoId: "abc",
            cache: cache,
            fetcher: fetcher
        )
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello")
        XCTAssertEqual(cues[1].text, "World")
    }

    // MARK: - Cache

    func testReturnsCachedOnHit() async throws {
        cache.set("cached_id", cues: [
            Cue(index: 0, time: 0, endTime: 1, text: "From cache")
        ])
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return self.status(500)
        }
        let cues = try await YouTubeCaptionExtractor.extract(
            videoId: "cached_id",
            cache: cache,
            fetcher: fetcher
        )
        XCTAssertEqual(calls, 0, "fetcher must not run when cache hits")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "From cache")
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
        let cues = try await YouTubeCaptionExtractor.extract(
            videoId: "fb", cache: cache, fetcher: fetcher
        )
        XCTAssertEqual(playerCalls, 2,
                       "should advance to second client after UNPLAYABLE")
        XCTAssertEqual(cues.count, 2)
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
        XCTAssertEqual(playerCalls, 3,
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
