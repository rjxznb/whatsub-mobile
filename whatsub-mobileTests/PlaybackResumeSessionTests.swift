import XCTest
@testable import whatsub_mobile

final class PlaybackResumeSessionTests: XCTestCase {
    func testPersistsAtMostEveryFiveSecondsAndForceFlushesLatestTime() {
        var session = PlaybackResumeSession(restoredPosition: 20)

        XCTAssertEqual(session.receiveTime(21, now: date(0)), .save(21))
        XCTAssertEqual(session.receiveTime(22, now: date(4.9)), .none)
        XCTAssertEqual(session.receiveTime(26, now: date(5)), .save(26))
        XCTAssertEqual(session.receiveTime(27, now: date(6)), .none)
        XCTAssertEqual(session.forceFlushDecision(now: date(6)), .save(27))
    }

    func testOnlyExplicitEndClearsAndTrailingTimesStaySuppressed() {
        var session = PlaybackResumeSession(restoredPosition: 99)

        XCTAssertEqual(session.receiveTime(100, now: date(0)), .save(100))
        XCTAssertEqual(session.markEnded(), .clear)
        XCTAssertEqual(session.receiveTime(100, now: date(6)), .none)
        XCTAssertEqual(session.forceFlushDecision(now: date(7)), .none)
        session.markPlaying()
        XCTAssertEqual(session.receiveTime(0, now: date(8)), .save(0))
    }

    func testRestoringIgnoresInitialZeroUntilReady() {
        var session = PlaybackResumeSession(restoredPosition: 120)
        let generation = session.beginReload()

        XCTAssertEqual(session.receiveTime(0, now: date(0)), .none)
        XCTAssertEqual(session.resumePosition, 120)

        session.markReady(generation: generation)
        XCTAssertEqual(session.receiveTime(120, now: date(1)), .save(120))
    }

    func testExplicitSeekInFinalSecondReopensCompletedSession() {
        var session = PlaybackResumeSession(restoredPosition: 100)
        XCTAssertEqual(session.markEnded(), .clear)

        XCTAssertEqual(
            session.markExplicitSeek(99.5, now: date(1)),
            .save(99.5)
        )
        XCTAssertEqual(session.resumePosition, 99.5)
    }

    func testPlayingReopensCompletionWhenNoTailWasSampled() {
        var session = PlaybackResumeSession(restoredPosition: nil)
        XCTAssertEqual(session.markEnded(), .clear)

        session.markPlaying()

        XCTAssertEqual(session.receiveTime(0, now: date(1)), .save(0))
    }

    func testReloadPreservesLatestPositionAndRejectsOldTimeout() {
        var session = PlaybackResumeSession(restoredPosition: 12)
        _ = session.receiveTime(47, now: date(0))

        let first = session.beginReload()
        let second = session.beginReload()

        XCTAssertEqual(session.resumePosition, 47)
        XCTAssertFalse(session.shouldAcceptTimeout(generation: first))
        XCTAssertTrue(session.shouldAcceptTimeout(generation: second))
        session.markReady(generation: second)
        XCTAssertFalse(session.shouldAcceptTimeout(generation: second))
    }

    func testInvalidTimesDoNotReplaceResumePosition() {
        var session = PlaybackResumeSession(restoredPosition: 8)

        XCTAssertEqual(session.receiveTime(.nan, now: date(0)), .none)
        XCTAssertEqual(session.receiveTime(-1, now: date(1)), .none)
        XCTAssertEqual(session.resumePosition, 8)
    }

    func testPausedTimerDoesNotRewriteAnUnchangedPersistedSecond() {
        var session = PlaybackResumeSession(restoredPosition: nil)

        XCTAssertEqual(session.receiveTime(12.2, now: date(0)), .save(12.2))
        XCTAssertEqual(session.receiveTime(12.8, now: date(5)), .none)
        XCTAssertEqual(session.receiveTime(13.1, now: date(10)), .save(13.1))
    }

    func testOnlyCurrentGenerationAcceptsFailureEvenAfterReady() {
        var session = PlaybackResumeSession(restoredPosition: 8)
        let first = session.beginReload()
        let current = session.beginReload()
        session.markReady(generation: current)

        XCTAssertFalse(session.isCurrent(generation: first))
        XCTAssertTrue(session.isCurrent(generation: current))
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
