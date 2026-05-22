import XCTest
@testable import whatsub_mobile

final class YouTubeIDTests: XCTestCase {
    func testWatchURL() {
        XCTAssertEqual(extractYouTubeID("https://www.youtube.com/watch?v=ECXAFUmdJkI"), "ECXAFUmdJkI")
    }
    func testWatchURLWithExtraParams() {
        XCTAssertEqual(extractYouTubeID("https://www.youtube.com/watch?v=ECXAFUmdJkI&t=90s&list=xx"), "ECXAFUmdJkI")
    }
    func testShortURL() {
        XCTAssertEqual(extractYouTubeID("https://youtu.be/ECXAFUmdJkI?t=12"), "ECXAFUmdJkI")
    }
    func testNonYouTube() {
        XCTAssertNil(extractYouTubeID("https://example.com/page"))
    }
}
