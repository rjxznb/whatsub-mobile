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
            AVPlayerLifecycleDecision.forEvent(.didPlayToEnd),
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
        let first = SeekRequest(seconds: 12, nonce: UUID())
        let newest = SeekRequest(seconds: 36, nonce: UUID())
        let afterReady = SeekRequest(seconds: 50, nonce: UUID())

        XCTAssertNil(state.queue(first))
        XCTAssertNil(state.queue(newest))
        XCTAssertEqual(state.markReady(), newest)
        XCTAssertEqual(state.queue(afterReady), afterReady)
    }

    func testNewPlaybackOperationInvalidatesOlderCompletion() {
        var revision = PlayerOperationRevision()

        let passiveRestore = revision.begin()
        let explicitSeek = revision.begin()

        XCTAssertFalse(revision.isCurrent(passiveRestore))
        XCTAssertTrue(revision.isCurrent(explicitSeek))
    }
}
