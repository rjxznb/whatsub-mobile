import XCTest
@testable import whatsub_mobile

final class AnalysisCheckpointStoreTests: XCTestCase {
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

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisCheckpointStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func cues(_ count: Int) -> [Cue] {
        (0..<count).map {
            Cue(index: $0, time: Double($0), endTime: Double($0) + 0.8, text: "line \($0)")
        }
    }

    private func analyzed(_ source: ArraySlice<Cue>) -> [Cue] {
        source.enumerated().map { offset, cue in
            Cue(
                index: cue.index,
                time: cue.time,
                endTime: cue.endTime,
                text: cue.text,
                translation: "译文 \(offset)"
            )
        }
    }

    private func validSummaryJSON() -> String {
        #"{"type":"summary","keyPhrases":[{"expression":"wrap up","meaningZh":"收尾","usage":"用于结束讨论"}],"learningGuide":{"verdict":"select_segments","overview":"This conversation demonstrates a clear and natural way to close a discussion while preserving a friendly tone.","contentOutline":["Review the final idea clearly","Close the discussion politely"],"cefrLevel":"B2","cefrReason":"The language requires contextual understanding of natural conversational closure.","recommendedFor":["Intermediate conversation learners"],"learningReasons":["It models a reusable way to finish a discussion naturally."],"cultureNotes":[],"studyTips":["Listen once and then shadow the final sentence."],"topSegments":[]},"contextProfile":{"theme":"Closing a discussion","participants":"Two speakers","setting":"A casual conversation","tone":"Friendly and conclusive","culturalContext":"","recurringConcepts":["Conversational closure"]}}"#
    }

    func testRoundTripPersistsCompletedBatchAndSummary() throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(50)
        var checkpoint = store.makeCheckpoint(sourceID: "youtube-1", cues: source)
        try checkpoint.recordBatch(index: 0, result: analyzed(source[0..<50]), sourceCues: source)
        checkpoint.recordSummary(AnalysisSummary(
            keyPhrases: [
                KeyPhrase(expression: "save up", meaningZh: "攒钱", usage: "Save up for it.")
            ],
            learningGuide: nil,
            contextProfile: nil
        ))

        try store.save(checkpoint)
        let loaded = try XCTUnwrap(store.load(sourceID: "youtube-1", cues: source))

        XCTAssertEqual(loaded.completedBatches[0]?.count, 50)
        XCTAssertEqual(loaded.completedSummary?.keyPhrases.first?.expression, "save up")
    }

    func testFingerprintUsesSourceAndNormalizedCueContent() {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(2)
        let same = [
            Cue(index: 99, time: 0, endTime: 0.8, text: "line 0\r\n"),
            Cue(index: 42, time: 1, endTime: 1.8, text: "line 1")
        ]

        XCTAssertEqual(
            store.fingerprint(sourceID: " youtube-1 ", cues: source),
            store.fingerprint(sourceID: "youtube-1", cues: same)
        )
        XCTAssertNotEqual(
            store.fingerprint(sourceID: "youtube-1", cues: source),
            store.fingerprint(sourceID: "youtube-2", cues: source)
        )
    }

    func testRejectsPartialAndIndexMismatchedBatches() throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(60)
        var checkpoint = store.makeCheckpoint(sourceID: "youtube-1", cues: source)

        XCTAssertThrowsError(
            try checkpoint.recordBatch(index: 0, result: analyzed(source[0..<49]), sourceCues: source)
        )

        var wrong = analyzed(source[0..<50])
        wrong[10].index = 999
        XCTAssertThrowsError(
            try checkpoint.recordBatch(index: 0, result: wrong, sourceCues: source)
        )
        XCTAssertTrue(checkpoint.completedBatches.isEmpty)
    }

    func testAcceptsTimestampRoundedToPromptPrecision() throws {
        let source = [Cue(index: 0, time: 1.234, endTime: 2.345, text: "Hello")]
        let rounded = [Cue(
            index: 0, time: 1.23, endTime: 2.35, text: "Hello", translation: "你好"
        )]
        var checkpoint = AnalysisCheckpoint(fingerprint: "test")

        XCTAssertNoThrow(
            try checkpoint.recordBatch(index: 0, result: rounded, sourceCues: source)
        )
    }

    func testLoadRejectsSummaryWhenNotAllBatchesAreComplete() throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(60)
        var checkpoint = store.makeCheckpoint(sourceID: "youtube-1", cues: source)
        try checkpoint.recordBatch(index: 0, result: analyzed(source[0..<50]), sourceCues: source)
        checkpoint.recordSummary(AnalysisSummary(
            keyPhrases: [
                KeyPhrase(expression: "save up", meaningZh: "攒钱", usage: "存钱以备将来")
            ],
            learningGuide: nil,
            contextProfile: nil
        ))
        try store.save(checkpoint)

        XCTAssertNil(try store.load(sourceID: "youtube-1", cues: source))
    }

    func testPersistedEmptySummaryResumesWithoutProviderRequest() async throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(1)
        var checkpoint = store.makeCheckpoint(sourceID: "youtube-1", cues: source)
        try checkpoint.recordBatch(
            index: 0,
            result: analyzed(source[0..<1]),
            sourceCues: source
        )
        checkpoint.recordSummary(AnalysisSummary(
            keyPhrases: [], learningGuide: nil, contextProfile: nil
        ))
        try store.save(checkpoint)
        let loaded = try XCTUnwrap(store.load(sourceID: "youtube-1", cues: source))
        let script = StreamScript([])
        let engine = AnalysisEngine(streamProvider: script.stream)

        let result = try await engine.analyze(
            source,
            completedBatches: loaded.completedBatches,
            completedSummary: loaded.completedSummary,
            onBatchCompleted: { _, _ in XCTFail("completed cue batch must not repeat") },
            onSummaryCompleted: { _ in XCTFail("completed summary must not repeat") },
            shouldBeginRequest: { true },
            onProgress: { _, _ in }
        )

        XCTAssertEqual(script.requestCount, 0)
        XCTAssertTrue(result.keyPhrases.isEmpty)
        XCTAssertNil(result.learningGuide)
        XCTAssertNil(result.contextProfile)
    }

    func testPersistedLegacyEmptyRawArraySummaryResumesWithoutProviderRequest() async throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(1)
        let fingerprint = store.fingerprint(sourceID: "youtube-1", cues: source)
        var checkpoint = store.makeCheckpoint(sourceID: "youtube-1", cues: source)
        try checkpoint.recordBatch(
            index: 0,
            result: analyzed(source[0..<1]),
            sourceCues: source
        )
        checkpoint.recordSummary(AnalysisSummary(
            keyPhrases: [], learningGuide: nil, contextProfile: nil
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(checkpoint)) as? [String: Any]
        )
        persisted["completedSummary"] = []
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: persisted).write(
            to: directory.appendingPathComponent("\(fingerprint).json")
        )
        let loaded = try XCTUnwrap(store.load(sourceID: "youtube-1", cues: source))
        let script = StreamScript([])
        let engine = AnalysisEngine(streamProvider: script.stream)

        XCTAssertNotNil(loaded.completedSummary)
        let result = try await engine.analyze(
            source,
            completedBatches: loaded.completedBatches,
            completedSummary: loaded.completedSummary,
            onBatchCompleted: { _, _ in XCTFail("completed cue batch must not repeat") },
            onSummaryCompleted: { _ in XCTFail("legacy empty summary must not repeat") },
            shouldBeginRequest: { true },
            onProgress: { _, _ in }
        )

        XCTAssertEqual(script.requestCount, 0)
        XCTAssertTrue(result.keyPhrases.isEmpty)
        XCTAssertNil(result.learningGuide)
        XCTAssertNil(result.contextProfile)
    }

    func testPersistedLegacyRawArraySummaryResumesWithoutProviderRequest() async throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(1)
        let fingerprint = store.fingerprint(sourceID: "youtube-1", cues: source)
        var checkpoint = store.makeCheckpoint(sourceID: "youtube-1", cues: source)
        try checkpoint.recordBatch(
            index: 0,
            result: analyzed(source[0..<1]),
            sourceCues: source
        )
        checkpoint.recordSummary(AnalysisSummary(
            keyPhrases: [
                KeyPhrase(expression: "save up", meaningZh: "攒钱", usage: "存钱以备将来")
            ],
            learningGuide: nil,
            contextProfile: nil
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(checkpoint)) as? [String: Any]
        )
        persisted["completedSummary"] = [[
            "expression": "save up",
            "meaningZh": "攒钱",
            "usage": "存钱以备将来",
        ]]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: persisted).write(
            to: directory.appendingPathComponent("\(fingerprint).json")
        )
        let loaded = try XCTUnwrap(store.load(sourceID: "youtube-1", cues: source))
        let script = StreamScript([])
        let engine = AnalysisEngine(streamProvider: script.stream)

        let result = try await engine.analyze(
            source,
            completedBatches: loaded.completedBatches,
            completedSummary: loaded.completedSummary,
            onBatchCompleted: { _, _ in XCTFail("completed cue batch must not repeat") },
            onSummaryCompleted: { _ in XCTFail("legacy summary must not repeat") },
            shouldBeginRequest: { true },
            onProgress: { _, _ in }
        )

        XCTAssertEqual(script.requestCount, 0)
        XCTAssertEqual(result.keyPhrases.first?.expression, "save up")
        XCTAssertNil(result.learningGuide)
        XCTAssertNil(result.contextProfile)
    }

    func testPruneDeletesOnlyCheckpointsOlderThanSevenDays() throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_000_000)
        var stale = store.makeCheckpoint(sourceID: "stale", cues: cues(1))
        stale.updatedAt = now.addingTimeInterval(-8 * 24 * 60 * 60)
        try store.save(stale)
        var fresh = store.makeCheckpoint(sourceID: "fresh", cues: cues(1))
        fresh.updatedAt = now.addingTimeInterval(-6 * 24 * 60 * 60)
        try store.save(fresh)

        try store.prune(now: now)

        XCTAssertNil(try store.load(sourceID: "stale", cues: cues(1)))
        XCTAssertNotNil(try store.load(sourceID: "fresh", cues: cues(1)))
    }

    func testCorruptCheckpointIsDiscardedInsteadOfBlockingImport() throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(1)
        let fingerprint = store.fingerprint(sourceID: "youtube-1", cues: source)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("\(fingerprint).json")
        try Data("not-json".utf8).write(to: file)

        XCTAssertNil(try store.load(sourceID: "youtube-1", cues: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInvalidatedLeaseCannotRecreateCancelledCheckpoint() throws {
        let lease = BYOKCheckpointLease()
        var callbackRan = false
        lease.invalidate {}

        XCTAssertThrowsError(
            try lease.withValid { callbackRan = true }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(callbackRan)
    }
}
