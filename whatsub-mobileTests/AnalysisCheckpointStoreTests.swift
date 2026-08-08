import XCTest
@testable import whatsub_mobile

final class AnalysisCheckpointStoreTests: XCTestCase {
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

    func testRoundTripPersistsCompletedBatchAndSummary() throws {
        let store = AnalysisCheckpointStore(directory: directory)
        let source = cues(50)
        var checkpoint = store.makeCheckpoint(sourceID: "youtube-1", cues: source)
        try checkpoint.recordBatch(index: 0, result: analyzed(source[0..<50]), sourceCues: source)
        checkpoint.recordSummary([
            KeyPhrase(expression: "save up", meaningZh: "攒钱", usage: "Save up for it.")
        ])

        try store.save(checkpoint)
        let loaded = try XCTUnwrap(store.load(sourceID: "youtube-1", cues: source))

        XCTAssertEqual(loaded.completedBatches[0]?.count, 50)
        XCTAssertEqual(loaded.completedSummary?.first?.expression, "save up")
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
        checkpoint.recordSummary([])
        try store.save(checkpoint)

        XCTAssertNil(try store.load(sourceID: "youtube-1", cues: source))
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
