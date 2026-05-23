import XCTest
@testable import whatsub_mobile
final class AppGroupTests: XCTestCase {
    func testRoundTrip() {
        AppGroup.setPendingImportURL("https://youtu.be/abc")
        XCTAssertEqual(AppGroup.pendingImportURL(), "https://youtu.be/abc")
        AppGroup.clearPendingImportURL()
        XCTAssertNil(AppGroup.pendingImportURL())
    }
}
