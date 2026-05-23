import XCTest
@testable import whatsub_mobile
final class ShareURLParseTests: XCTestCase {
    func testExtractsURLFromText() {
        XCTAssertEqual(firstURL(in: "看这个 https://www.youtube.com/watch?v=abc 不错"), "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(firstURL(in: "https://youtu.be/xyz"), "https://youtu.be/xyz")
        XCTAssertNil(firstURL(in: "no url here"))
    }
}
