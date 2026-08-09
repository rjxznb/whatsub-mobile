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

    func testClipQueuedBeforeReadyIsDeliveredExactlyOnceAfterReady() {
        var delivery = YouTubeClipCommandDeliveryState()
        let command = YouTubeClipPlaybackCommand.play(start: 1, end: 2, rate: 0.75)

        XCTAssertNil(delivery.queue(command))
        XCTAssertEqual(delivery.markReady(), command)
        XCTAssertNil(delivery.markReady())
    }

    func testClipJavaScriptContainsBoundaryAndPauseLogic() {
        let play = YouTubeClipPlaybackCommand.play(start: 1, end: 2, rate: 0.75)
        let script = YouTubeEmbedView.clipJavaScript(for: play) ?? ""
        XCTAssertTrue(script.contains("seekTo(1.0"))
        XCTAssertTrue(script.contains("whatsubClipEnd = 2.0"))
        XCTAssertTrue(script.contains("getAvailablePlaybackRates"))
        XCTAssertTrue(script.contains("playVideo"))
        let stop = YouTubeClipPlaybackCommand.stop()
        let stopScript = YouTubeEmbedView.clipJavaScript(for: stop) ?? ""
        XCTAssertTrue(stopScript.contains("pauseVideo"))
    }
}
