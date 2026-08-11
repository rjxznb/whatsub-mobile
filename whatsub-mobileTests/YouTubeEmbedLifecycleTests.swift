import XCTest
@testable import whatsub_mobile

final class YouTubeEmbedLifecycleTests: XCTestCase {
    func testResumeHTMLSeeksThenPausesWithoutAutoplay() throws {
        let html = YouTubeEmbedView.html(
            videoId: "dQw4w9WgXcQ",
            startSeconds: nil,
            resumeSeconds: 42
        )

        let seek = try XCTUnwrap(html.range(of: "window.player.seekTo(42, false)"))
        let pause = try XCTUnwrap(html.range(of: "window.player.pauseVideo()"))
        XCTAssertLessThan(seek.lowerBound, pause.lowerBound)
        XCTAssertFalse(html.contains("autoplay: 1"))
    }

    func testHTMLForwardsEndedAndPlayerErrors() {
        let html = YouTubeEmbedView.html(
            videoId: "dQw4w9WgXcQ",
            startSeconds: nil,
            resumeSeconds: nil
        )

        XCTAssertTrue(html.contains("YT.PlayerState.ENDED"))
        XCTAssertTrue(html.contains("{ type: 'ended' }"))
        XCTAssertTrue(html.contains("onError:"))
        XCTAssertTrue(html.contains("{ type: 'failure' }"))
    }

    func testBridgeDecoderMapsEverySupportedEvent() {
        let nonce = UUID(uuidString: "D9428888-122B-11E1-B85C-61CD3CBB3210")!

        XCTAssertEqual(YouTubeBridgeEvent.decode(["type": "ready"]), .ready)
        XCTAssertEqual(
            YouTubeBridgeEvent.decode(["type": "time", "sec": 12.5]),
            .time(12.5)
        )
        XCTAssertEqual(
            YouTubeBridgeEvent.decode([
                "type": "clipEnded",
                "nonce": nonce.uuidString
            ]),
            .clipEnded(nonce)
        )
        XCTAssertEqual(YouTubeBridgeEvent.decode(["type": "failure"]), .failure)
        XCTAssertEqual(YouTubeBridgeEvent.decode(["type": "ended"]), .ended)
    }

    func testBridgeDecoderRejectsMalformedMessages() {
        XCTAssertNil(YouTubeBridgeEvent.decode("ready"))
        XCTAssertNil(YouTubeBridgeEvent.decode(["type": "time"]))
        XCTAssertNil(YouTubeBridgeEvent.decode(["type": "clipEnded", "nonce": "bad"] ))
        XCTAssertNil(YouTubeBridgeEvent.decode(["type": "unknown"]))
    }
}
