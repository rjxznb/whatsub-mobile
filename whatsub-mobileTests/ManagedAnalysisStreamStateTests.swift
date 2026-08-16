import XCTest
@testable import whatsub_mobile

final class ManagedAnalysisStreamStateTests: XCTestCase {
    private func streamCue(_ index: Int, translation: String) -> ManagedAnalysisStreamCue {
        ManagedAnalysisStreamCue(
            type: .cue,
            index: index,
            time: Double(index),
            endTime: Double(index) + 0.5,
            text: "Cue \(index)",
            translation: translation,
            isKeyPoint: true,
            highlightWords: ["Cue"],
            keyNotes: ["Cue": "note"],
            highlightTranslations: ["Cue": "提示"]
        )
    }

    private func cueEvent(
        id: Int64,
        batch: Int = 0,
        attempt: Int = 1,
        index: Int = 0,
        translation: String = "译文"
    ) -> ManagedAnalysisCueStreamEvent {
        .init(
            eventId: id,
            jobId: "job",
            eventType: "cue",
            batchIndex: batch,
            attempt: attempt,
            cueIndex: index,
            payload: streamCue(index, translation: translation),
            createdAt: id
        )
    }

    private func resetEvent(
        id: Int64,
        batch: Int = 0,
        abandoned: Int,
        next: Int?
    ) -> ManagedAnalysisBatchResetStreamEvent {
        .init(
            eventId: id,
            jobId: "job",
            eventType: "batch_reset",
            batchIndex: batch,
            attempt: abandoned,
            cueIndex: nil,
            payload: .init(abandonedAttempt: abandoned, nextAttempt: next),
            createdAt: id
        )
    }

    func testDeduplicatesReplayAndIgnoresOutOfOrderEvents() {
        var state = ManagedAnalysisStreamState()
        state.apply(.cue(cueEvent(id: 2, translation: "new")))
        state.apply(.cue(cueEvent(id: 2, translation: "duplicate")))
        state.apply(.cue(cueEvent(id: 1, translation: "old")))

        XCTAssertEqual(state.lastEventID, 2)
        XCTAssertEqual(state.previews.count, 1)
        XCTAssertEqual(state.previews.values.first?.translation, "new")
    }

    func testRetryResetRebasesValidatedPreviewsAndReplacesOnlyOneCue() {
        var state = ManagedAnalysisStreamState()
        state.apply(.cue(cueEvent(id: 1, attempt: 1, index: 0, translation: "retained zero")))
        state.apply(.cue(cueEvent(id: 2, attempt: 1, index: 1, translation: "retained one")))
        state.apply(.batchReset(resetEvent(id: 3, abandoned: 1, next: 2)))

        XCTAssertEqual(state.currentAttemptByBatch[0], 2)
        XCTAssertEqual(state.previews.count, 2)
        XCTAssertEqual(Set(state.previews.keys.map(\.attempt)), [2])
        XCTAssertEqual(Set(state.previews.values.map(\.translation)), ["retained zero", "retained one"])

        state.apply(.cue(cueEvent(id: 4, attempt: 1, index: 0, translation: "late stale")))
        state.apply(.cue(cueEvent(id: 5, attempt: 2, index: 1, translation: "replacement one")))

        XCTAssertEqual(state.lastEventID, 5)
        XCTAssertEqual(state.currentAttemptByBatch[0], 2)
        XCTAssertEqual(state.previews.count, 2)
        XCTAssertEqual(Set(state.previews.values.map(\.translation)), ["retained zero", "replacement one"])
    }

    func testTerminalResetStillRemovesAbandonedPreviews() {
        var state = ManagedAnalysisStreamState()
        state.apply(.cue(cueEvent(id: 1, attempt: 1, index: 0)))
        state.apply(.cue(cueEvent(id: 2, attempt: 1, index: 1)))

        state.apply(.batchReset(resetEvent(id: 3, abandoned: 1, next: nil)))

        XCTAssertTrue(state.previews.isEmpty)
        XCTAssertNil(state.currentAttemptByBatch[0])
    }

    func testHigherAttemptCueRecoversWhenResetWasMissed() {
        var state = ManagedAnalysisStreamState()
        state.apply(.cue(cueEvent(id: 1, attempt: 1, translation: "old")))
        state.apply(.cue(cueEvent(id: 3, attempt: 2, translation: "recovered")))

        XCTAssertEqual(state.currentAttemptByBatch[0], 2)
        XCTAssertEqual(state.previews.count, 1)
        XCTAssertEqual(state.previews.values.first?.translation, "recovered")
    }

    func testSnapshotReplacesUncommittedStateAndSetsCursorAndQueue() {
        var state = ManagedAnalysisStreamState()
        state.apply(.cue(cueEvent(id: 99, batch: 3, attempt: 7)))
        let snapshotCue = cueEvent(id: 10, batch: 1, attempt: 2, index: 5, translation: "snapshot")
        state.apply(.snapshot(.init(
            jobId: "job",
            status: .queued,
            totalCues: 20,
            completedCues: 5,
            completedBatchCursor: 0,
            latestEventId: 10,
            errorCode: nil,
            jobsAhead: 2,
            estimatedStartSeconds: 75,
            currentAttempt: .init(batchIndex: 1, attempt: 2, cues: [snapshotCue])
        )))

        XCTAssertEqual(state.lastEventID, 10)
        XCTAssertEqual(state.previews.count, 1)
        XCTAssertEqual(state.currentAttemptByBatch, [1: 2])
        XCTAssertEqual(state.jobsAhead, 2)
        XCTAssertEqual(state.estimatedStartSeconds, 75)
    }

    func testResyncClearsOnlyPreviewsUntilFollowingSnapshot() {
        var state = ManagedAnalysisStreamState()
        state.applyDurable(.init(
            jobId: "job",
            entryId: "entry",
            status: .running,
            completedCues: 1,
            totalCues: 2,
            nextBatchCursor: 0,
            batches: [],
            errorCode: nil
        ))
        state.apply(.cue(cueEvent(id: 3)))
        state.apply(.resync(.init(reason: .cursorExpired)))

        XCTAssertNil(state.lastEventID)
        XCTAssertTrue(state.previews.isEmpty)
        XCTAssertEqual(state.completedCues, 1)
        XCTAssertTrue(state.needsDurableResync)
    }

    func testDurableTakeoverRemovesOnlyCommittedBatchPreviews() {
        var state = ManagedAnalysisStreamState()
        state.apply(.cue(cueEvent(id: 1, batch: 0, index: 0)))
        state.apply(.cue(cueEvent(id: 2, batch: 1, index: 1)))
        state.applyDurable(.init(
            jobId: "job",
            entryId: "entry",
            status: .running,
            completedCues: 1,
            totalCues: 2,
            nextBatchCursor: 0,
            batches: [.init(batchIndex: 0, subtitles: [])],
            errorCode: nil
        ))

        XCTAssertEqual(Set(state.previews.keys.map(\.batchIndex)), [1])
        XCTAssertNil(state.currentAttemptByBatch[0])
        XCTAssertEqual(state.currentAttemptByBatch[1], 1)
    }
}
