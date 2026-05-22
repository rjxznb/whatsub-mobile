import XCTest
@testable import whatsub_mobile

final class APIErrorTests: XCTestCase {
    func testServerErrorMapping() {
        XCTAssertEqual(APIError.server(400, "wrong_code").chinese, "验证码错误")
        XCTAssertEqual(APIError.server(400, "too_many_attempts").chinese, "尝试次数过多，请重新获取验证码")
        XCTAssertEqual(APIError.unauthorized.chinese, "登录已过期，请重新登录")
    }

    func testUnknownServerErrorFallsBackToCode() {
        XCTAssertEqual(APIError.server(500, "boom").chinese, "服务器错误（500）")
    }
}
