import XCTest
@testable import whatsub_mobile

final class AnalysisEngineTests: XCTestCase {

    private final class StreamScript: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String]
        private(set) var requestCount = 0

        init(_ responses: [String]) { self.responses = responses }

        func stream(_: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            requestCount += 1
            let response = responses.isEmpty ? "" : responses.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.yield(response)
                continuation.finish()
            }
        }
    }

    // MARK: - Helpers

    /// Build a minimal Cue via JSON decode (mirrors the lenient Decodable init).
    private func cueFixture(index: Int) -> Cue {
        let json = """
        {"index":\(index),"time":\(Double(index)),"endTime":\(Double(index) + 1.5),"text":"word \(index)","translation":"词 \(index)","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        """.data(using: .utf8)!
        var cue = try! JSONDecoder().decode(Cue.self, from: json)
        cue.index = index
        return cue
    }

    private func validSummaryJSON(keyPhrases: String = "[]") -> String {
        #"{"type":"summary","keyPhrases":\#(keyPhrases),"learningGuide":{"verdict":"select_segments","overview":"这段访谈通过自然对话展示人物如何先认可对方观点，再用缓和语气委婉表达不同意见，并维持轻松友好的交流氛围。","contentOutline":["先说明讨论背景和人物之间的关系","再展示缓和分歧时常用的自然表达"],"cefrLevel":"B2","cefrReason":"语速自然，并包含需要结合上下文和说话语气理解的委婉表达。","recommendedFor":["希望提升真实会话理解的学习者"],"learningReasons":["包含可直接迁移到讨论场景的表达"],"cultureNotes":[],"studyTips":["先盲听，再跟读推荐片段"],"topSegments":[]},"contextProfile":{"theme":"委婉沟通与分歧处理","participants":"采访者与演员","setting":"轻松访谈","tone":"自然、友好并带有幽默感","culturalContext":"","recurringConcepts":["先认可对方观点"]}}"#
    }

    // MARK: - parseCue / parseSummary (streaming path)
    //
    // Post 2026-06-21 streaming refactor — AnalysisEngine no longer offers
    // a parseCueLines(raw:) helper. The streaming pipeline funnels every
    // line through `JsonLineParser` → `AnalysisEngine.parseCue(obj:)` /
    // `parseSummary(obj:)`. The tests below drive the same JSONL inputs
    // through that pipe and assert the same end-state.

    private func driveLines(_ raw: String) -> (cues: [Cue], summary: AnalysisSummary?) {
        let parser = JsonLineParser()
        var cues: [Cue] = []
        var summary: AnalysisSummary?
        // Append trailing newline so the parser sees a clean line boundary
        // even when the test fixture's last line omits it.
        let input = raw.hasSuffix("\n") ? raw : raw + "\n"
        parser.feed(input) { obj in
            if let cue = AnalysisEngine.parseCue(obj) { cues.append(cue) }
            if let parsed = AnalysisEngine.parseSummary(obj, durationSec: 20, cues: []) {
                summary = parsed
            }
        }
        parser.flush { obj in
            if let cue = AnalysisEngine.parseCue(obj) { cues.append(cue) }
            if let parsed = AnalysisEngine.parseSummary(obj, durationSec: 20, cues: []) {
                summary = parsed
            }
        }
        return (cues, summary)
    }

    func testParseCueLinesSkipsNonJSONAndSummary() {
        let raw = """
        {"type":"cue","index":0,"time":0,"endTime":1.6,"text":"Hi","translation":"嗨","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        garbage line
        {"type":"cue","index":1,"time":1.6,"endTime":3,"text":"Save up","translation":"攒钱","isKeyPoint":true,"highlightWords":["Save up"],"keyNotes":{"Save up":"攒钱的意思"},"highlightTranslations":{"Save up":"攒钱"}}
        """
        let cues = driveLines(raw).cues
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].translation, "攒钱")
        XCTAssertEqual(cues[1].highlightWords, ["Save up"])
    }

    func testParseCueLinesSkipsSummaryLine() {
        let raw = """
        {"type":"cue","index":0,"time":0,"endTime":1.0,"text":"Hello","translation":"你好","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        \(validSummaryJSON(keyPhrases: #"[{"expression":"save up","meaningZh":"攒钱","usage":"存钱"}]"#))
        """
        let cues = driveLines(raw).cues
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello")
    }

    func testParseCueLinesReturnsEmptyForGarbage() {
        let cues = driveLines("not json at all\n\nalso bad\n").cues
        XCTAssertTrue(cues.isEmpty)
    }

    func testParseSummaryLine() {
        let raw = validSummaryJSON(
            keyPhrases: #"[{"expression":"save up","meaningZh":"攒钱","usage":"存钱"}]"#
        )
        let kp = driveLines(raw).summary?.keyPhrases ?? []
        XCTAssertEqual(kp.first?.expression, "save up")
        XCTAssertEqual(kp.first?.meaningZh, "攒钱")
        XCTAssertEqual(kp.first?.usage, "存钱")
    }

    func testParseSummaryLineReturnsEmptyWhenNoSummaryLine() {
        let raw = #"{"type":"cue","index":0,"time":0,"endTime":1,"text":"hi","translation":"嗨","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}"#
        let kp = driveLines(raw).summary?.keyPhrases ?? []
        XCTAssertTrue(kp.isEmpty)
    }

    func testParseSummaryLineMultipleKeyPhrases() {
        let raw = validSummaryJSON(
            keyPhrases: #"[{"expression":"catch up","meaningZh":"赶上","usage":"用于表示追赶进度"},{"expression":"save up","meaningZh":"攒钱","usage":"存钱备用"}]"#
        )
        let kp = driveLines(raw).summary?.keyPhrases ?? []
        XCTAssertEqual(kp.count, 2)
        XCTAssertEqual(kp[0].expression, "catch up")
        XCTAssertEqual(kp[1].expression, "save up")
    }

    // MARK: - batches

    func testBatching() {
        let cues = (0..<120).map { i in cueFixture(index: i) }
        XCTAssertEqual(AnalysisEngine.batches(cues, size: 50).count, 3)
    }

    func testBatchingExact() {
        let cues = (0..<50).map { i in cueFixture(index: i) }
        XCTAssertEqual(AnalysisEngine.batches(cues, size: 50).count, 1)
    }

    func testBatchingEmpty() {
        XCTAssertEqual(AnalysisEngine.batches([], size: 50).count, 0)
    }

    func testBatchingPreservesAllCues() {
        let cues = (0..<73).map { i in cueFixture(index: i) }
        let batched = AnalysisEngine.batches(cues, size: 50)
        XCTAssertEqual(batched.count, 2)
        XCTAssertEqual(batched[0].count, 50)
        XCTAssertEqual(batched[1].count, 23)
    }

    func testBoundedSummaryPreservesFirstAndLastCompleteCueDeterministically() throws {
        let manyCues = (0..<30).map { index in
            Cue(
                index: index,
                time: Double(index) * 1.5,
                endTime: Double(index) * 1.5 + 1.25,
                text: "cue-\(index)-" + String(repeating: "x", count: 2_000),
                translation: "译文 \(index)"
            )
        }

        let first = try AnalysisPrompts.boundedSummaryMessages(manyCues, maxCharacters: 20_000)
        let second = try AnalysisPrompts.boundedSummaryMessages(manyCues, maxCharacters: 20_000)
        let serialized = try JSONSerialization.data(withJSONObject: first.map {
            ["role": $0.role, "content": $0.content]
        })
        let text = String(decoding: serialized, as: UTF8.self)

        XCTAssertEqual(first.map(\.content), second.map(\.content))
        XCTAssertTrue(text.contains(manyCues.first!.text))
        XCTAssertTrue(text.contains(manyCues.last!.text))
        let userContent = try XCTUnwrap(first.last?.content)
        XCTAssertTrue(userContent.contains(#""index":0"#))
        XCTAssertTrue(userContent.contains(#""time":0"#))
        XCTAssertTrue(userContent.contains(#""endTime":1.25"#))
        XCTAssertLessThanOrEqual(text.count, 20_000)
    }

    // MARK: - AnalysisJson.assembled

    func testAssembledFactory() {
        let cues = (0..<3).map { i in cueFixture(index: i) }
        let kp = [KeyPhrase(expression: "save up", meaningZh: "攒钱", usage: "存钱")]
        let result = AnalysisJson.assembled(subtitles: cues, keyPhrases: kp)
        XCTAssertEqual(result.subtitles.count, 3)
        XCTAssertEqual(result.keyPhrases.count, 1)
        XCTAssertEqual(result.keyPhrases[0].expression, "save up")
    }

    // MARK: - Cancellation

    /// Closing the import sheet mid-analysis must actually STOP the run.
    /// Before this, `analyze` had no cancellation checks: the detached Task
    /// kept streaming, then auto-synced the finished entry to the cloud —
    /// the user "cancelled" and still got a video (and a quota slot) they
    /// never asked for.
    ///
    /// Deterministic by construction: the body spins until cancellation is
    /// observable, THEN calls analyze — so the first checkCancellation must
    /// throw before any network request is attempted (the BYOK settings
    /// below point nowhere, so a request would fail differently).
    func testAnalyzeThrowsCancellationBeforeAnyNetworkCall() async {
        var settings = LlmSettings()
        settings.useManagedRelay = false
        settings.baseUrl = "https://127.0.0.1:1/v1"   // never reachable
        settings.apiKey = "test-key"
        settings.model = "test-model"
        let engine = AnalysisEngine(client: ChatCompletionsClient(settings: settings))
        let cues = (0..<3).map { i in cueFixture(index: i) }

        let task = Task { () -> Result<AnalysisJson, Error> in
            while !Task.isCancelled { await Task.yield() }
            do { return .success(try await engine.analyze(cues) { _, _ in }) }
            catch { return .failure(error) }
        }
        task.cancel()

        guard case .failure(let err) = await task.value else {
            return XCTFail("analyze should throw once the task is cancelled")
        }
        XCTAssertTrue(err is CancellationError, "expected CancellationError, got \(err)")
    }

    func testResumeSkipsCompletedBatchAndReportsNewBatchBeforeSummary() async throws {
        let source = (0..<60).map { cueFixture(index: $0) }
        let first = Array(source[0..<50])
        let secondJSON = source[50..<60].map { cue in
            "{\"index\":\(cue.index),\"time\":\(cue.time),\"endTime\":\(cue.endTime),\"text\":\"\(cue.text)\",\"translation\":\"译\",\"isKeyPoint\":false,\"highlightWords\":[],\"keyNotes\":{},\"highlightTranslations\":{}}"
        }.joined(separator: "\n")
        let summaryJSON = validSummaryJSON()
        let script = StreamScript([secondJSON, summaryJSON])
        let engine = AnalysisEngine(streamProvider: script.stream)
        var completed: [Int] = []

        let result = try await engine.analyze(
            source,
            completedBatches: [0: first],
            completedSummary: nil,
            onBatchCompleted: { index, _ in completed.append(index) },
            onSummaryCompleted: { _ in completed.append(99) },
            shouldBeginRequest: { true },
            onProgress: { _, _ in }
        )

        XCTAssertEqual(script.requestCount, 2)
        XCTAssertEqual(completed, [1, 99])
        XCTAssertEqual(result.subtitles.count, 60)
    }

    func testAnalyzeUsesKnownVideoDurationForSegmentExtendingPastLastCue() async throws {
        let source = [Cue(index: 0, time: 55, endTime: 58, text: "Closing thought")]
        let analyzedCue = #"{"index":0,"time":55,"endTime":58,"text":"Closing thought","translation":"结尾想法","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}"#
        let segment = #"{"startTime":57,"endTime":60,"title":"结尾重点片段","reason":"该片段与最后一条字幕在时间上有重叠，并且持续到视频结尾。","focusExpressions":[]}"#
        let summary = validSummaryJSON().replacingOccurrences(
            of: #""topSegments":[]"#,
            with: #""topSegments":[\#(segment)]"#
        )
        let script = StreamScript([analyzedCue, summary])
        let engine = AnalysisEngine(streamProvider: script.stream)

        let result = try await engine.analyze(
            source,
            durationSec: 60,
            onProgress: { _, _ in }
        )

        XCTAssertEqual(result.learningGuide?.topSegments.first?.startTime, 57)
        XCTAssertEqual(result.learningGuide?.topSegments.first?.endTime, 60)
    }

    func testInvalidSummaryDoesNotCheckpointEmptyCompletion() async throws {
        let source = [cueFixture(index: 0)]
        let analyzedCue = #"{"index":0,"time":0,"endTime":1.5,"text":"word 0","translation":"译文","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}"#
        let script = StreamScript([analyzedCue, #"{"type":"summary","keyPhrases":[]}"#])
        let engine = AnalysisEngine(streamProvider: script.stream)
        var checkpointed = false

        let result = try await engine.analyze(
            source,
            durationSec: nil,
            completedBatches: [:],
            completedSummary: nil,
            onBatchCompleted: { _, _ in },
            onSummaryCompleted: { _ in checkpointed = true },
            shouldBeginRequest: { true },
            onProgress: { _, _ in }
        )

        XCTAssertFalse(checkpointed)
        XCTAssertNil(result.learningGuide)
        XCTAssertNil(result.contextProfile)
    }

    func testCompletedSummaryResumeDoesNotOpenAnotherProviderRequest() async throws {
        let source = [cueFixture(index: 0)]
        let draft = try XCTUnwrap(
            try VideoLearningParser.parseSummary(
                Data(validSummaryJSON().utf8),
                durationSec: 20,
                cues: source
            ).learningGuide
        )
        let profile = try XCTUnwrap(
            try VideoLearningParser.parseSummary(
                Data(validSummaryJSON().utf8),
                durationSec: 20,
                cues: source
            ).contextProfile
        )
        let completed = AnalysisSummary(
            keyPhrases: [],
            learningGuide: draft,
            contextProfile: profile
        )
        let script = StreamScript([])
        let engine = AnalysisEngine(streamProvider: script.stream)

        let result = try await engine.analyze(
            source,
            completedBatches: [0: source],
            completedSummary: completed,
            onBatchCompleted: { _, _ in XCTFail("completed batch must not repeat") },
            onSummaryCompleted: { _ in XCTFail("completed summary must not repeat") },
            shouldBeginRequest: { true },
            onProgress: { _, _ in }
        )

        XCTAssertEqual(script.requestCount, 0)
        XCTAssertEqual(result.learningGuide?.verdict, .selectSegments)
        XCTAssertEqual(result.contextProfile?.theme, profile.theme)
    }

    func testAnalyzeRetriesPartialBatchBeforeCheckpointCallback() async {
        let source = (0..<2).map { cueFixture(index: $0) }
        let partial = "{\"index\":0,\"time\":0,\"endTime\":1.5,\"text\":\"word 0\",\"translation\":\"译\",\"isKeyPoint\":false,\"highlightWords\":[],\"keyNotes\":{},\"highlightTranslations\":{}}"
        let script = StreamScript([partial, partial, partial, partial])
        let engine = AnalysisEngine(streamProvider: script.stream)
        var checkpointed = false

        do {
            _ = try await engine.analyze(
                source,
                completedBatches: [:],
                completedSummary: nil,
                onBatchCompleted: { _, _ in checkpointed = true },
                onSummaryCompleted: { _ in },
                shouldBeginRequest: { true },
                onProgress: { _, _ in }
            )
            XCTFail("partial batch must fail")
        } catch is AnalysisContentError {
            XCTAssertFalse(checkpointed)
            XCTAssertEqual(script.requestCount, 4)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBackgroundGateStopsBeforeOpeningNextBatch() async {
        let source = (0..<60).map { cueFixture(index: $0) }
        let firstJSON = source[0..<50].map { cue in
            "{\"index\":\(cue.index),\"time\":\(cue.time),\"endTime\":\(cue.endTime),\"text\":\"\(cue.text)\",\"translation\":\"译\",\"isKeyPoint\":false,\"highlightWords\":[],\"keyNotes\":{},\"highlightTranslations\":{}}"
        }.joined(separator: "\n")
        let script = StreamScript([firstJSON])
        let engine = AnalysisEngine(streamProvider: script.stream)
        var allowRequest = true

        do {
            _ = try await engine.analyze(
                source,
                completedBatches: [:],
                completedSummary: nil,
                onBatchCompleted: { _, _ in allowRequest = false },
                onSummaryCompleted: { _ in },
                shouldBeginRequest: { allowRequest },
                onProgress: { _, _ in }
            )
            XCTFail("analysis should pause between batches")
        } catch is AnalysisPausedError {
            XCTAssertEqual(script.requestCount, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAnalysisEmitsTransportParsingAndBatchLifecycle() async throws {
        let source = [cueFixture(index: 0)]
        let cueJSON = """
        {"index":0,"time":0,"endTime":1.5,"text":"word 0","translation":"译",\
        "isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        """
        let summaryJSON = validSummaryJSON()
        var requestIndex = 0
        let engine = AnalysisEngine(diagnosticStreamProvider: { _, lifecycle in
            lifecycle(.connecting)
            lifecycle(.responseOpen)
            lifecycle(.firstContent)
            let response = requestIndex == 0 ? cueJSON : summaryJSON
            requestIndex += 1
            return AsyncThrowingStream { continuation in
                continuation.yield(response)
                continuation.finish()
            }
        })
        var events: [AnalysisStreamEvent] = []

        _ = try await engine.analyze(
            source,
            completedBatches: [:],
            completedSummary: nil,
            onBatchCompleted: { _, _ in },
            onSummaryCompleted: { _ in },
            shouldBeginRequest: { true },
            onProgress: { _, _ in },
            onDiagnostic: { events.append($0) }
        )

        XCTAssertEqual(events.map(\.stage), [
            .preparingRequest, .connecting, .responseOpen, .firstContent,
            .parsing, .batchComplete,
            .preparingRequest, .connecting, .responseOpen, .firstContent,
        ])
        XCTAssertEqual(events.first(where: { $0.stage == .parsing })?.parsedCues, 1)
        XCTAssertEqual(events.first(where: { $0.stage == .batchComplete })?.batch, 0)
    }
}
