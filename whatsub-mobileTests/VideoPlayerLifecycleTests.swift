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
}
