import XCTest
@testable import whatsub_mobile

final class VideoSourceTests: XCTestCase {
    func testYouTubeHosts() {
        XCTAssertEqual(VideoSource.from(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(VideoSource.from(url: "https://youtu.be/dQw4w9WgXcQ"), .youtube)
    }
    func testBilibiliHosts() {
        XCTAssertEqual(VideoSource.from(url: "https://www.bilibili.com/video/BV1xx411c7mu"), .bilibili)
        XCTAssertEqual(VideoSource.from(url: "https://b23.tv/abc123"), .bilibili)
    }
    func testOtherAndGarbage() {
        XCTAssertEqual(VideoSource.from(url: "https://vimeo.com/12345"), .other)
        XCTAssertEqual(VideoSource.from(url: "not a url"), .other)
    }
    func testIsLikelyYouTubeId() {
        XCTAssertTrue(VideoSource.isLikelyYouTubeId("dQw4w9WgXcQ"))
        XCTAssertFalse(VideoSource.isLikelyYouTubeId("BV1xx411c7mu"))
        XCTAssertFalse(VideoSource.isLikelyYouTubeId("u_0123456789"))
    }
}
