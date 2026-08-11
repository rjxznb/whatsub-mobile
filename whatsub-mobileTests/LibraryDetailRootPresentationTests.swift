import XCTest
@testable import whatsub_mobile

final class LibraryDetailRootPresentationTests: XCTestCase {
    func testRefreshFailureWithEntryKeepsContentAndExposesInlineError() {
        let presentation = LibraryDetailRootPresentation.resolve(
            hasEntry: true,
            loading: false,
            errorMessage: "刷新失败"
        )

        XCTAssertEqual(
            presentation,
            .content(inlineRefreshError: "刷新失败")
        )
    }

    func testInitialLoadFailureWithoutEntryUsesBlockingError() {
        let presentation = LibraryDetailRootPresentation.resolve(
            hasEntry: false,
            loading: false,
            errorMessage: "加载失败"
        )

        XCTAssertEqual(presentation, .blockingError("加载失败"))
    }

    func testExistingEntryWinsWhileRefreshIsLoading() {
        let presentation = LibraryDetailRootPresentation.resolve(
            hasEntry: true,
            loading: true,
            errorMessage: nil
        )

        XCTAssertEqual(presentation, .content(inlineRefreshError: nil))
    }

    func testInitialLoadWithoutEntryStillUsesLoadingState() {
        let presentation = LibraryDetailRootPresentation.resolve(
            hasEntry: false,
            loading: true,
            errorMessage: nil
        )

        XCTAssertEqual(presentation, .loading)
    }
}
