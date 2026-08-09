import XCTest
@testable import whatsub_mobile

final class YouTubeClipPlaybackControllerTests: XCTestCase {
    @MainActor
    func testRepeatedPlayCreatesDistinctCommands() {
        let controller = YouTubeClipPlaybackController()
        XCTAssertTrue(controller.play(start: 10, end: 12, rate: 1))
        let first = controller.command
        XCTAssertTrue(controller.play(start: 10, end: 12, rate: 1))
        XCTAssertNotEqual(first?.nonce, controller.command?.nonce)
    }

    @MainActor
    func testPlayRejectsInvalidRangeAndNumbers() {
        let controller = YouTubeClipPlaybackController()
        XCTAssertFalse(controller.play(start: 2, end: 2, rate: 1))
        XCTAssertFalse(controller.play(start: .nan, end: 3, rate: 1))
        XCTAssertFalse(controller.play(start: 1, end: .infinity, rate: 1))
        XCTAssertNil(controller.command)
    }

    @MainActor
    func testPlayClampsNegativeStartAndRate() {
        let controller = YouTubeClipPlaybackController()
        XCTAssertTrue(controller.play(start: -2, end: 3, rate: 9))
        XCTAssertEqual(controller.command?.start, 0)
        XCTAssertEqual(controller.command?.rate, 2)
    }

    @MainActor
    func testStopAndRateCommandsUseFreshNonces() {
        let controller = YouTubeClipPlaybackController()
        XCTAssertTrue(controller.play(start: 1, end: 2, rate: 1))
        controller.setRate(0.5)
        let rateNonce = controller.command?.nonce
        controller.stop()
        XCTAssertNotEqual(rateNonce, controller.command?.nonce)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testStaleClipCompletionCannotStopNewerClip() throws {
        let controller = YouTubeClipPlaybackController()
        XCTAssertTrue(controller.play(start: 1, end: 2, rate: 1))
        let nonceA = try XCTUnwrap(controller.command?.nonce)

        XCTAssertTrue(controller.play(start: 3, end: 4, rate: 1))
        let nonceB = try XCTUnwrap(controller.command?.nonce)

        controller.clipEnded(nonce: nonceA)
        XCTAssertTrue(controller.isPlaying)

        controller.clipEnded(nonce: nonceB)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testActiveClipCompletionPublishesFreshStopCommand() throws {
        let controller = YouTubeClipPlaybackController()
        XCTAssertTrue(controller.play(start: 1, end: 2, rate: 1))
        let activePlay = try XCTUnwrap(controller.command)

        controller.clipEnded(nonce: activePlay.nonce)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.consumerRebuildReplaySnapshot)
        let completionStop = try XCTUnwrap(controller.command)
        XCTAssertEqual(completionStop.kind, .stop)
        XCTAssertNotEqual(completionStop.nonce, activePlay.nonce)
    }

    @MainActor
    func testCompletionStopCancelsPendingReplayBeforeConsumerBecomesReady() throws {
        let controller = YouTubeClipPlaybackController()
        XCTAssertTrue(controller.play(start: 1, end: 2, rate: 1))
        let replay = try XCTUnwrap(controller.consumerRebuildReplaySnapshot)
        var delivery = YouTubeClipCommandDeliveryState()
        XCTAssertEqual(delivery.queue(replay), [])

        controller.clipEnded(nonce: replay.nonce)
        let completionStop = try XCTUnwrap(controller.command)
        XCTAssertEqual(completionStop.kind, .stop)
        XCTAssertEqual(delivery.queue(completionStop), [])

        XCTAssertEqual(delivery.markReady(), [completionStop])
    }

    @MainActor
    func testConsumerRebuildReplaySnapshotIsNilWhenNoClipIsActive() throws {
        let controller = YouTubeClipPlaybackController()
        XCTAssertNil(controller.consumerRebuildReplaySnapshot)

        XCTAssertTrue(controller.play(start: 1, end: 2, rate: 1))
        let activeNonce = try XCTUnwrap(controller.command?.nonce)
        controller.clipEnded(nonce: activeNonce)
        XCTAssertNil(controller.consumerRebuildReplaySnapshot)

        XCTAssertTrue(controller.play(start: 3, end: 4, rate: 1))
        controller.stop()
        XCTAssertNil(controller.consumerRebuildReplaySnapshot)
    }

    @MainActor
    func testConsumerRebuildReplaySnapshotRestoresTheActivePlayCommand() throws {
        let controller = YouTubeClipPlaybackController()
        XCTAssertTrue(controller.play(start: 3, end: 7, rate: 0.75))
        let livePlay = try XCTUnwrap(controller.command)
        let replay = try XCTUnwrap(controller.consumerRebuildReplaySnapshot)

        XCTAssertEqual(replay.kind, .play)
        XCTAssertEqual(replay.start, 3)
        XCTAssertEqual(replay.end, 7)
        XCTAssertEqual(replay.rate, 0.75)
        XCTAssertEqual(replay.nonce, livePlay.nonce)
    }

    @MainActor
    func testConsumerRebuildReplaySnapshotKeepsActivePlayAfterLiveRateEvent() throws {
        let controller = YouTubeClipPlaybackController()
        XCTAssertTrue(controller.play(start: 3, end: 7, rate: 0.75))
        let activeNonce = try XCTUnwrap(controller.command?.nonce)

        controller.setRate(1.5)

        let liveRate = try XCTUnwrap(controller.command)
        XCTAssertEqual(liveRate.kind, .setRate)
        XCTAssertEqual(liveRate.rate, 1.5)

        let replay = try XCTUnwrap(controller.consumerRebuildReplaySnapshot)
        XCTAssertEqual(replay.kind, .play)
        XCTAssertEqual(replay.start, 3)
        XCTAssertEqual(replay.end, 7)
        XCTAssertEqual(replay.rate, 1.5)
        XCTAssertEqual(replay.nonce, activeNonce)
    }

    func testClipQueuedBeforeReadyIsDeliveredExactlyOnceAfterReady() {
        var delivery = YouTubeClipCommandDeliveryState()
        let command = YouTubeClipPlaybackCommand.play(start: 1, end: 2, rate: 0.75)

        XCTAssertEqual(delivery.queue(command), [])
        XCTAssertEqual(delivery.markReady(), [command])
        XCTAssertEqual(delivery.markReady(), [])
    }

    func testClipQueuedAfterReadyDeliversImmediatelyOncePerNonce() {
        var delivery = YouTubeClipCommandDeliveryState()
        let command = YouTubeClipPlaybackCommand.play(start: 1, end: 2, rate: 0.75)

        XCTAssertEqual(delivery.markReady(), [])
        XCTAssertEqual(delivery.queue(command), [command])
        XCTAssertEqual(delivery.queue(command), [])
    }

    func testPreReadyPlayThenRateDeliversBothCommandsInOrder() {
        var delivery = YouTubeClipCommandDeliveryState()
        let play = YouTubeClipPlaybackCommand.play(start: 1, end: 2, rate: 0.75)
        let rate = YouTubeClipPlaybackCommand.setRate(0.5)

        XCTAssertEqual(delivery.queue(play), [])
        XCTAssertEqual(delivery.queue(rate), [])
        XCTAssertEqual(delivery.markReady(), [play, rate])
    }

    func testPreReadyPlayThenStopDeliversOnlyStop() {
        var delivery = YouTubeClipCommandDeliveryState()
        let play = YouTubeClipPlaybackCommand.play(start: 1, end: 2, rate: 0.75)
        let stop = YouTubeClipPlaybackCommand.stop()

        XCTAssertEqual(delivery.queue(play), [])
        XCTAssertEqual(delivery.queue(stop), [])
        XCTAssertEqual(delivery.markReady(), [stop])
    }

    func testClipJavaScriptCarriesNonceThroughBoundaryCompletion() {
        let play = YouTubeClipPlaybackCommand.play(start: 1, end: 2, rate: 0.75)
        let script = YouTubeEmbedView.clipJavaScript(for: play) ?? ""
        XCTAssertTrue(script.contains("seekTo(1.0"))
        XCTAssertTrue(script.contains("whatsubClipEnd = 2.0"))
        XCTAssertTrue(script.contains("whatsubClipNonce = \"\(play.nonce.uuidString)\""))
        XCTAssertTrue(script.contains("getAvailablePlaybackRates"))
        XCTAssertTrue(script.contains("playVideo"))
        let iframe = YouTubeEmbedView.html(videoId: "dQw4w9WgXcQ", startSeconds: nil)
        XCTAssertTrue(iframe.contains("nonce: clipNonce"))
        let stop = YouTubeClipPlaybackCommand.stop()
        let stopScript = YouTubeEmbedView.clipJavaScript(for: stop) ?? ""
        XCTAssertTrue(stopScript.contains("whatsubClipNonce = null"))
        XCTAssertTrue(stopScript.contains("pauseVideo"))
    }
}
