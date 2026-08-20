import XCTest
@testable import whatsub_mobile

final class VideoLearningModelsTests: XCTestCase {
    private final class RequestCaptureProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var responseData = Data("{}".utf8)
        private static var storedRequest: URLRequest?

        static func prepare(response: Data = Data("{}".utf8)) {
            lock.lock()
            responseData = response
            storedRequest = nil
            lock.unlock()
        }

        static func request() -> URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return storedRequest
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4_096)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                captured.httpBody = data
            }
            Self.lock.lock()
            Self.storedRequest = captured
            let data = Self.responseData
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var cues: [Cue] {
        [Cue(
            index: 0,
            time: 10,
            endTime: 14,
            text: "I see your point.",
            translation: "我明白你的意思。"
        )]
    }

    private var validSummaryJSON: Data {
        Data(#"""
        {"type":"summary","keyPhrases":[{"expression":"see your point","meaningZh":"理解你的观点","usage":"用于先认可对方观点，再自然补充自己的不同看法。"}],"learningGuide":{"verdict":"select_segments","overview":"这段访谈通过自然对话展示人物如何先认可对方观点，再用缓和语气委婉表达不同意见，并维持轻松友好的交流氛围。","contentOutline":["先说明讨论背景和人物之间的关系","再展示缓和分歧时常用的自然表达"],"cefrLevel":"B2","cefrReason":"语速自然，并包含需要结合上下文和说话语气理解的委婉表达。","recommendedFor":["希望提升真实会话理解的学习者"],"learningReasons":["包含可直接迁移到讨论场景的表达"],"cultureNotes":[],"studyTips":["先盲听，再跟读推荐片段"],"topSegments":[{"startTime":10,"endTime":14,"title":"委婉认同","reason":"展示先认可再表达分歧的方式","focusExpressions":["see your point"]}]},"contextProfile":{"theme":"委婉沟通与分歧处理","participants":"采访者与演员","setting":"轻松访谈","tone":"自然、友好并带有幽默感","culturalContext":"","recurringConcepts":["先认可对方观点","再表达不同意见"]}}
        """#.utf8)
    }

    private func parsedSummary() throws -> AnalysisSummary {
        try VideoLearningParser.parseSummary(validSummaryJSON, durationSec: 20, cues: cues)
    }

    private func makeAPI() -> WhatsubAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureProtocol.self]
        return WhatsubAPI(session: URLSession(configuration: configuration))
    }

    private func analysisWithDerivedFields() throws -> AnalysisJson {
        let summary = try parsedSummary()
        return AnalysisJson.assembled(
            subtitles: cues,
            keyPhrases: summary.keyPhrases,
            learningGuide: summary.learningGuide.map {
                LearningGuide(draft: $0, generatedAt: 1_000)
            },
            contextProfile: summary.contextProfile,
            learningGuideSourceFingerprint: "client-must-not-send"
        )
    }

    func testStrictSummaryParsesScoreFreeEnvelope() throws {
        let summary = try VideoLearningParser.parseSummary(
            validSummaryJSON,
            durationSec: 20,
            cues: cues
        )

        XCTAssertEqual(summary.keyPhrases.first?.expression, "see your point")
        XCTAssertEqual(summary.learningGuide?.verdict, .selectSegments)
        XCTAssertEqual(summary.learningGuide?.cefrLevel, .b2)
        XCTAssertEqual(summary.contextProfile?.theme, "委婉沟通与分歧处理")
    }

    func testSummaryRejectsNumericScore() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validSummaryJSON) as? [String: Any]
        )
        var guide = try XCTUnwrap(object["learningGuide"] as? [String: Any])
        guide["score"] = 8.4
        object["learningGuide"] = guide
        let scoredSummaryJSON = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try VideoLearningParser.parseSummary(
            scoredSummaryJSON,
            durationSec: 20,
            cues: cues
        ))
    }

    func testSummaryRejectsUnknownEnvelopeKey() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validSummaryJSON) as? [String: Any]
        )
        object["rating"] = "excellent"

        XCTAssertThrowsError(try VideoLearningParser.parseSummary(
            JSONSerialization.data(withJSONObject: object),
            durationSec: 20,
            cues: cues
        ))
    }

    func testSummaryRejectsSegmentOutsideDuration() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validSummaryJSON) as? [String: Any]
        )
        var guide = try XCTUnwrap(object["learningGuide"] as? [String: Any])
        var segments = try XCTUnwrap(guide["topSegments"] as? [[String: Any]])
        segments[0]["endTime"] = 21
        guide["topSegments"] = segments
        object["learningGuide"] = guide

        XCTAssertThrowsError(try VideoLearningParser.parseSummary(
            JSONSerialization.data(withJSONObject: object),
            durationSec: 20,
            cues: cues
        ))
    }

    func testSummaryRejectsSegmentWithoutCueEvidence() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validSummaryJSON) as? [String: Any]
        )
        var guide = try XCTUnwrap(object["learningGuide"] as? [String: Any])
        var segments = try XCTUnwrap(guide["topSegments"] as? [[String: Any]])
        segments[0]["startTime"] = 1
        segments[0]["endTime"] = 2
        guide["topSegments"] = segments
        object["learningGuide"] = guide

        XCTAssertThrowsError(try VideoLearningParser.parseSummary(
            JSONSerialization.data(withJSONObject: object),
            durationSec: 20,
            cues: cues
        ))
    }

    func testContextProfileAllowsEmptyUnsupportedCulture() throws {
        let summary = try VideoLearningParser.parseSummary(
            validSummaryJSON,
            durationSec: 20,
            cues: cues
        )
        XCTAssertEqual(summary.contextProfile?.culturalContext, "")
    }

    func testDeepGlossRoundTripsOptionalEmptySections() throws {
        let value = DeepGlossResult(
            contextualMeaning: "这里表示理解对方的观点。",
            toneAndSubtext: "语气友好，为后续分歧留出空间。",
            slangOrIdiom: "",
            culturalContext: "",
            naturalAlternatives: ["I understand your perspective."],
            usageWarning: ""
        )

        let decoded = try JSONDecoder().decode(
            DeepGlossResult.self,
            from: JSONEncoder().encode(value)
        )
        XCTAssertEqual(decoded.naturalAlternatives, ["I understand your perspective."])
        XCTAssertEqual(decoded.slangOrIdiom, "")
    }

    func testLearningGuidePatchUsesNarrowDerivedPayload() async throws {
        let summary = try parsedSummary()
        let draft = try XCTUnwrap(summary.learningGuide)
        let profile = try XCTUnwrap(summary.contextProfile)
        var acceptedGuide = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any]
        )
        acceptedGuide["generatedAt"] = 2_000
        let profileObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let response = try JSONSerialization.data(withJSONObject: [
            "learningGuide": acceptedGuide,
            "contextProfile": profileObject,
            "analysisFingerprint": "server-fingerprint",
        ])
        RequestCaptureProtocol.prepare(response: response)

        let result = try await makeAPI().updateLearningGuide(
            id: "entry",
            expectedFingerprint: "expected-fingerprint",
            guide: draft,
            profile: profile,
            token: "token"
        )

        let request = try XCTUnwrap(RequestCaptureProtocol.request())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertTrue(request.url?.path.hasSuffix("/entry/entry/learning-guide") == true)
        XCTAssertEqual(body["expectedAnalysisFingerprint"] as? String, "expected-fingerprint")
        XCTAssertNotNil(body["learningGuide"])
        XCTAssertNotNil(body["contextProfile"])
        XCTAssertNil(body["subtitles"])
        XCTAssertNil(body["learningGuideSourceFingerprint"])
        XCTAssertEqual(result.analysisFingerprint, "server-fingerprint")
    }

    func testFullSyncSendsGuideAndProfileButNeverClientStamp() async throws {
        RequestCaptureProtocol.prepare()

        try await makeAPI().syncLibraryEntry(
            youtubeId: "abcdefghijk",
            sourceUrl: "https://www.youtube.com/watch?v=abcdefghijk",
            title: "Title",
            durationSec: 20,
            transcriptSrt: "",
            analysis: try analysisWithDerivedFields(),
            token: "token"
        )

        let request = try XCTUnwrap(RequestCaptureProtocol.request())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let analysis = try XCTUnwrap(body["analysisJson"] as? [String: Any])
        XCTAssertNotNil(analysis["learningGuide"])
        XCTAssertNotNil(analysis["contextProfile"])
        XCTAssertNil(analysis["learningGuideSourceFingerprint"])
    }

    func testCueUpdatePreservesDerivedLearningFieldsWhenCallerSuppliesThem() async throws {
        RequestCaptureProtocol.prepare()

        try await makeAPI().updateLibraryEntryCues(
            entryId: "entry",
            analysis: try analysisWithDerivedFields(),
            transcriptSrt: "",
            token: "token"
        )

        let request = try XCTUnwrap(RequestCaptureProtocol.request())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let analysis = try XCTUnwrap(body["analysisJson"] as? [String: Any])
        XCTAssertNotNil(analysis["learningGuide"])
        XCTAssertNotNil(analysis["contextProfile"])
        XCTAssertEqual(
            analysis["learningGuideSourceFingerprint"] as? String,
            "client-must-not-send"
        )
    }

    func testThumbnailRepairUsesOwnedLightweightEndpoint() async throws {
        RequestCaptureProtocol.prepare()
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9]).base64EncodedString()

        try await makeAPI().repairLibraryThumbnail(
            entryID: "entry id",
            thumbData: jpeg,
            token: "TOKEN"
        )

        let request = try XCTUnwrap(RequestCaptureProtocol.request())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.percentEncodedPath, "/api/library/sync/entry%20id/thumb")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
        )
        XCTAssertEqual(body, ["thumbData": jpeg])
    }
}
