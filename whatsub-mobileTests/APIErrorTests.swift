import XCTest
@testable import whatsub_mobile

final class APIErrorTests: XCTestCase {
    func testServerErrorMapping() {
        // Warmth pass 2026-06-07: error strings rewritten to sound friendly
        // (audit-all-error-messages). Asserts pinned to the new copy.
        XCTAssertEqual(APIError.server(400, "wrong_code").chinese, "验证码不对，再确认一下。")
        XCTAssertEqual(APIError.server(400, "too_many_attempts").chinese, "尝试次数有点多了，重新获取一次验证码吧。")
        XCTAssertEqual(APIError.unauthorized.chinese, "登录信息过期了，重新登录一下就好。")
    }

    func testUnknownServerErrorFallsBackToCode() {
        XCTAssertEqual(APIError.server(500, "boom").chinese, "服务器错误（500）")
    }
}
