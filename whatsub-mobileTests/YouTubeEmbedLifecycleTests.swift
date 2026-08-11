import XCTest
@testable import whatsub_mobile

final class YouTubeEmbedLifecycleTests: XCTestCase {
    func testResumeHTMLSeeksAheadThenConfirmsPausedWithABound() throws {
        let html = YouTubeEmbedView.html(
            videoId: "dQw4w9WgXcQ",
            startSeconds: nil,
            resumeSeconds: 42
        )

        let seek = try XCTUnwrap(html.range(of: "window.player.seekTo(restoreTarget, true)"))
        let pause = try XCTUnwrap(html.range(
            of: "window.player.pauseVideo()",
            options: [],
            range: seek.upperBound..<html.endIndex
        ))
        XCTAssertLessThan(seek.lowerBound, pause.lowerBound)
        XCTAssertTrue(html.contains("restoreAttempts >= 40"))
        XCTAssertTrue(html.contains("Math.abs(currentTime - restoreTarget) <= 2"))
        XCTAssertFalse(html.contains("seekTo(42, false)"))
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
        let onError = html.range(of: "onError: function()")!
        let failure = html.range(of: "{ type: 'failure' }", range: onError.lowerBound..<html.endIndex)!
        let invalidation = html.range(
            of: "window.whatsubRestoreRevision += 1",
            range: onError.lowerBound..<failure.lowerBound
        )
        XCTAssertNotNil(invalidation)
    }

    func testBridgeDecoderMapsEverySupportedEvent() {
        let nonce = UUID(uuidString: "D9428888-122B-11E1-B85C-61CD3CBB3210")!

        XCTAssertEqual(YouTubeBridgeEvent.decode(["type": "surfaceReady"]), .surfaceReady)
        XCTAssertEqual(YouTubeBridgeEvent.decode(["type": "ready"]), .ready)
        XCTAssertEqual(YouTubeBridgeEvent.decode(["type": "playing"]), .playing)
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

    func testResumeReadinessWaitsForConfirmedPlayerTime() throws {
        let html = YouTubeEmbedView.html(
            videoId: "dQw4w9WgXcQ",
            startSeconds: nil,
            resumeSeconds: 42
        )

        let surfaceReady = try XCTUnwrap(html.range(of: "{ type: 'surfaceReady' }"))
        let seek = try XCTUnwrap(html.range(of: "window.player.seekTo(restoreTarget, true)"))
        let confirmed = try XCTUnwrap(html.range(of: "Math.abs(currentTime - restoreTarget) <= 2"))
        let restoredReady = try XCTUnwrap(html.range(
            of: "window.whatsubSignalReady();",
            options: [],
            range: confirmed.lowerBound..<html.endIndex
        ))

        XCTAssertLessThan(surfaceReady.lowerBound, seek.lowerBound)
        XCTAssertLessThan(confirmed.lowerBound, restoredReady.lowerBound)
    }

    func testRestorePolicyClampsHugeAndPastDurationPositions() {
        XCTAssertEqual(
            YouTubeRestorePolicy.target(
                savedSeconds: .greatestFiniteMagnitude,
                durationSeconds: nil
            ),
            YouTubeRestorePolicy.maximumSeconds
        )
        XCTAssertEqual(
            YouTubeRestorePolicy.target(savedSeconds: 150, durationSeconds: 100),
            99.75,
            accuracy: 0.001
        )
    }

    func testExplicitSeekCancelsPassiveRestoreAndStartsPlayback() {
        let html = YouTubeEmbedView.html(
            videoId: "dQw4w9WgXcQ",
            startSeconds: nil,
            resumeSeconds: 42
        )

        XCTAssertTrue(html.contains("window.whatsubExplicitSeek = function(seconds)"))
        XCTAssertTrue(html.contains("window.whatsubRestoreRevision += 1"))
        XCTAssertTrue(html.contains("window.player.playVideo()"))
    }

    func testReusableSurfaceSurvivesRotationButReloadGenerationRebuildsIt() {
        var state = YouTubeSurfaceReuseState()

        XCTAssertEqual(state.action(for: "entry-1-generation-1"), .rebuild)
        XCTAssertTrue(state.pause())
        XCTAssertEqual(state.action(for: "entry-1-generation-1"), .reuse)
        XCTAssertTrue(state.deactivate())
        XCTAssertFalse(state.deactivate())
        XCTAssertEqual(state.action(for: "entry-1-generation-1"), .rebuild)
        XCTAssertEqual(state.action(for: "entry-1-generation-2"), .rebuild)
    }

    func testBridgeCachesReadinessAndTerminalEventsDuringHandoffGap() {
        var state = YouTubeBridgeHandoffState()

        XCTAssertEqual(state.record(.surfaceReady, hasConsumer: false), [])
        XCTAssertEqual(state.record(.ready, hasConsumer: false), [])
        XCTAssertEqual(state.record(.time(12), hasConsumer: false), [])
        XCTAssertEqual(state.record(.failure, hasConsumer: false), [])

        let handoff = state.bind()
        XCTAssertTrue(handoff.surfaceReady)
        XCTAssertFalse(handoff.playerReady)
        XCTAssertEqual(handoff.queuedEvents, [.failure])
        XCTAssertEqual(state.bind().queuedEvents, [.failure])
    }

    func testDeliveredFailureStaysStickyAcrossLaterCoordinatorHandoffs() {
        var state = YouTubeBridgeHandoffState()

        XCTAssertEqual(state.record(.surfaceReady, hasConsumer: true), [.surfaceReady])
        XCTAssertEqual(state.record(.ready, hasConsumer: true), [.ready])
        XCTAssertEqual(state.record(.failure, hasConsumer: true), [.failure])

        let handoff = state.bind()
        XCTAssertTrue(handoff.surfaceReady)
        XCTAssertFalse(handoff.playerReady)
        XCTAssertEqual(handoff.queuedEvents, [.failure])
    }

    func testFailureSuppressesLateReadinessForCurrentCoordinator() {
        var state = YouTubeBridgeHandoffState()

        XCTAssertEqual(state.record(.surfaceReady, hasConsumer: true), [.surfaceReady])
        XCTAssertEqual(state.record(.failure, hasConsumer: true), [.failure])
        XCTAssertEqual(state.record(.ready, hasConsumer: true), [])

        let handoff = state.bind()
        XCTAssertFalse(handoff.playerReady)
        XCTAssertEqual(handoff.queuedEvents, [.failure])
    }
}
