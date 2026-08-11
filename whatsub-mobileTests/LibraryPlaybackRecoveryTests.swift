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
}
