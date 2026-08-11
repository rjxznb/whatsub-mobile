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
}
