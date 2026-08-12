import XCTest
@testable import whatsub_mobile

final class VideoPlayerLifecycleTests: XCTestCase {
    func testReadyWithResumeSeeksButDoesNotPlay() {
        XCTAssertEqual(
            AVPlayerLifecycleDecision.ready(resumeSeconds: 42),
            .seekPaused(42)
        )
        XCTAssertEqual(
            AVPlayerLifecycleDecision.ready(resumeSeconds: nil),
            .ready
        )
    }

    func testFailedAndEndedMapToDistinctCallbacks() {
        XCTAssertEqual(
            AVPlayerLifecycleDecision.forEvent(.itemFailed),
            .failure
        )
        XCTAssertEqual(
            AVPlayerLifecycleDecision.forEvent(.didPlayToEnd(115)),
            .ended
        )
    }

    func testExplicitSeekStillSeeksAndPlays() {
        XCTAssertEqual(
            AVPlayerLifecycleDecision.explicitSeek(seconds: 17),
            .seekAndPlay(17)
        )
    }

    func testInvalidResumeFallsBackToOrdinaryReady() {
        XCTAssertEqual(
            AVPlayerLifecycleDecision.ready(resumeSeconds: .nan),
            .ready
        )
        XCTAssertEqual(
            AVPlayerLifecycleDecision.ready(resumeSeconds: -1),
            .ready
        )
    }

    func testNewestExplicitSeekWaitsForReadyAndThenDeliversImmediately() {
        var state = PlayerSeekDeliveryState()
        let owner = PlayerOperationOwner()
        let first = SeekRequest(seconds: 12, nonce: UUID())
        let newest = SeekRequest(seconds: 36, nonce: UUID())
        let afterReady = SeekRequest(seconds: 50, nonce: UUID())

        XCTAssertNil(state.queue(
            first,
            operationToken: owner.begin(),
            operationOwner: owner
        ))
        XCTAssertNil(state.queue(
            newest,
            operationToken: owner.begin(),
            operationOwner: owner
        ))
        XCTAssertEqual(
            state.markReady(operationOwner: owner)?.request,
            newest
        )
        XCTAssertEqual(
            state.queue(
                afterReady,
                operationToken: owner.begin(),
                operationOwner: owner
            )?.request,
            afterReady
        )
    }

    func testPreReadySeekIsDroppedAfterParentCancelsPlaybackOperations() {
        var state = PlayerSeekDeliveryState()
        let owner = PlayerOperationOwner()
        let request = SeekRequest(seconds: 42, nonce: UUID())

        XCTAssertNil(state.queue(
            request,
            operationToken: owner.begin(),
            operationOwner: owner
        ))
        owner.cancelAll()

        XCTAssertNil(state.markReady(operationOwner: owner))
    }

    func testNewPlaybackOperationInvalidatesOlderCompletion() {
        var revision = PlayerOperationRevision()

        let passiveRestore = revision.begin()
        let explicitSeek = revision.begin()

        XCTAssertFalse(revision.isCurrent(passiveRestore))
        XCTAssertTrue(revision.isCurrent(explicitSeek))
    }

    func testSharedOperationOwnerMakesDetachAndReplacementOrderSafe() {
        let owner = PlayerOperationOwner()
        let oldRestore = owner.begin()
        let replacementSeek = owner.begin()

        // A late detach from the old coordinator must not cancel newer work.
        XCTAssertFalse(owner.invalidate(oldRestore))
        XCTAssertTrue(owner.isCurrent(replacementSeek))
        XCTAssertTrue(owner.invalidate(replacementSeek))
        XCTAssertFalse(owner.isCurrent(replacementSeek))
    }

    func testParentCancellationInvalidatesPendingOperationBeforePauseOrReload() {
        let owner = PlayerOperationOwner()
        let pending = owner.begin()

        owner.cancelAll()

        XCTAssertFalse(owner.isCurrent(pending))
        let replacement = owner.begin()
        XCTAssertTrue(owner.isCurrent(replacement))
    }

    func testSeekAcknowledgementRequiresSuccessfulCurrentExecution() {
        XCTAssertFalse(PlayerSeekAcceptance.av(finished: false, operationIsCurrent: true))
        XCTAssertFalse(PlayerSeekAcceptance.av(finished: true, operationIsCurrent: false))
        XCTAssertTrue(PlayerSeekAcceptance.av(finished: true, operationIsCurrent: true))

        XCTAssertFalse(PlayerSeekAcceptance.javascript(resultWasTrue: false, errorWasNil: true))
        XCTAssertFalse(PlayerSeekAcceptance.javascript(resultWasTrue: true, errorWasNil: false))
        XCTAssertTrue(PlayerSeekAcceptance.javascript(resultWasTrue: true, errorWasNil: true))
    }

    func testNativeRestoreClampsHugeAndPastDurationPositions() {
        XCTAssertGreaterThan(AVPlayerRestorePolicy.seekToleranceSeconds, 0)
        XCTAssertEqual(
            AVPlayerRestorePolicy.target(
                savedSeconds: .greatestFiniteMagnitude,
                durationSeconds: nil
            ),
            AVPlayerRestorePolicy.maximumSeconds
        )
        XCTAssertEqual(
            AVPlayerLifecycleDecision.ready(
                resumeSeconds: 150,
                durationSeconds: 100
            ),
            .seekPaused(99.75)
        )
    }

    func testConsumedSeekDoesNotReplayAfterSurfaceRebuild() {
        var state = PlayerSeekCommandState()
        let old = SeekRequest(seconds: 30, nonce: UUID())
        let fresh = SeekRequest(seconds: 80, nonce: UUID())

        state.submit(old)
        XCTAssertEqual(state.pending, old)
        XCTAssertTrue(state.consume(nonce: old.nonce))
        XCTAssertNil(state.pending)

        // A new coordinator reads the parent-owned state and sees no command.
        XCTAssertNil(state.pending)
        state.submit(fresh)
        XCTAssertFalse(state.consume(nonce: old.nonce))
        XCTAssertEqual(state.pending, fresh)

        state.cancelPending()
        XCTAssertNil(state.pending)
    }
}
