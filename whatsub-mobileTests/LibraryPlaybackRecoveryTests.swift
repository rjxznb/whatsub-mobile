import XCTest
@testable import whatsub_mobile

final class LibraryPlaybackRecoveryTests: XCTestCase {
    func testYouTubeReloadRebuildsWithoutDetailRefresh() {
        XCTAssertEqual(
            LibraryPlayerRecoveryAction.forSource(.youtube),
            .rebuildYouTube
        )
    }

    func testOSSReloadRefreshesSignedURLThenRebuildsPlayer() {
        XCTAssertEqual(
            LibraryPlayerRecoveryAction.forSource(.oss),
            .refreshDetailThenRebuildAVPlayer
        )
    }

    func testBothSourcesExposeReloadWithSourceSpecificHelp() {
        let youtube = LibraryPlayerErrorPresentation.forSource(.youtube)
        XCTAssertEqual(youtube.buttonTitle, "重新加载")
        XCTAssertTrue(youtube.isVPNRelated)
        XCTAssertTrue(youtube.detail.contains("VPN"))

        let oss = LibraryPlayerErrorPresentation.forSource(.oss)
        XCTAssertEqual(oss.buttonTitle, "重新加载")
        XCTAssertFalse(oss.isVPNRelated)
        XCTAssertFalse(oss.detail.contains("VPN"))
    }

    func testDetailWiresExplicitSeekAndPlayingIntoResumeSession() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/LibraryDetailView.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains(".onChange(of: vm.seek)"))
        XCTAssertTrue(source.contains("playbackSession.markExplicitSeek"))
        XCTAssertEqual(
            source.components(separatedBy: "onPlaying: { handlePlayerPlaying").count - 1,
            2
        )
        XCTAssertTrue(source.contains("playbackSession.markPlaying()"))
    }

    func testDetailOwnsOneReusableYouTubeSurfaceAcrossLayouts() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/LibraryDetailView.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains("@StateObject private var youtubeSurface"))
        XCTAssertTrue(source.contains("reusableSurface: youtubeSurface"))
        XCTAssertTrue(source.contains("surfaceKey: \"\\(entry.id)-\\(generation)\""))
    }

    func testOnlyNewestOSSReloadRevisionCanPublish() {
        var state = LibraryPlaybackReloadState()

        state.begin(generation: 1)
        state.begin(generation: 2)

        XCTAssertFalse(state.accept(generation: 1))
        XCTAssertTrue(state.accept(generation: 2))
        XCTAssertNil(state.activeGeneration)
    }

    func testDetailKeepsOneActiveSourceAndCancelsSupersededOSSTask() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/LibraryDetailView.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var activePlayerSource"))
        XCTAssertTrue(source.contains("@State private var ossReloadTask"))
        XCTAssertTrue(source.contains("ossReloadTask?.cancel()"))
        XCTAssertTrue(source.contains("vm.publishPlaybackDetail(refreshed)"))
    }

    func testDetailOwnsPendingSeekUntilPlayerConsumesIt() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/LibraryDetailView.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var playerSeekState"))
        XCTAssertTrue(source.contains("seek: playerSeekState.pending"))
        XCTAssertEqual(source.components(separatedBy: "onSeekConsumed:").count - 1, 2)
        XCTAssertTrue(source.contains("playerSeekState.consume(nonce:"))
    }

    func testYouTubeUsesStableBridgeProxyInsideFreshContainers() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Components/YouTubeEmbedView.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains("final class YouTubeBridgeProxy"))
        XCTAssertTrue(source.contains("final class YouTubeWebViewContainer"))
        XCTAssertTrue(source.contains("func makeUIView(context: Context) -> YouTubeWebViewContainer"))
        XCTAssertTrue(source.contains("private var bridgeProxy"))
    }

    func testDetailDeactivatesOnSourceSwitchButOnlyPausesOnTemporaryExit() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/LibraryDetailView.swift"
        ), encoding: .utf8)

        XCTAssertEqual(
            source.components(separatedBy: "youtubeSurface.deactivate()").count - 1,
            1
        )
        XCTAssertTrue(source.contains("youtubeSurface.pause()"))
        XCTAssertTrue(source.contains("avOperationOwner.cancelAll()"))
    }

    func testPlayerWrappersUseCompletionBasedSeekAcceptance() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let nativeSource = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Components/VideoPlayerView.swift"
        ), encoding: .utf8)
        let youtubeSource = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Components/YouTubeEmbedView.swift"
        ), encoding: .utf8)

        XCTAssertTrue(nativeSource.contains("PlayerSeekAcceptance.av"))
        XCTAssertTrue(youtubeSource.contains("PlayerSeekAcceptance.javascript"))
    }


    func testReappearanceReusesPreparedPlayerWithoutResettingReadiness() {
        XCTAssertEqual(
            LibraryPlaybackPreparationAction.forPrepared(false),
            .prepare
        )
        XCTAssertEqual(
            LibraryPlaybackPreparationAction.forPrepared(true),
            .resumeExisting
        )
    }
}
