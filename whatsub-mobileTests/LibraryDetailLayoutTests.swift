import XCTest
@testable import whatsub_mobile

final class LibraryDetailLayoutTests: XCTestCase {
    func testOrientationChangesGeometryWithoutChangingPlayerSurfaceIdentity() {
        let portrait = LibraryDetailSurfaceLayout.resolve(isLandscape: false)
        let landscape = LibraryDetailSurfaceLayout.resolve(isLandscape: true)

        XCTAssertEqual(portrait.playerSurfaceIdentity, landscape.playerSurfaceIdentity)
        XCTAssertNotEqual(portrait.geometry, landscape.geometry)
    }
}
