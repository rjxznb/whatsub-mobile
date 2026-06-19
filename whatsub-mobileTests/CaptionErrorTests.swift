import XCTest
@testable import whatsub_mobile

final class CaptionErrorTests: XCTestCase {

    func testNetworkErrorMessage() {
        let underlying = URLError(.notConnectedToInternet)
        let err = CaptionError.network(underlying)
        XCTAssertEqual(err.errorDescription, "网络错误,请检查 VPN 或网络连接")
    }

    func testHTTPErrorMessageIncludesStatus() {
        XCTAssertEqual(CaptionError.http(status: 503).errorDescription,
                       "YouTube 接口暂时不可用 (HTTP 503)")
    }

    func testVideoUnavailableMessage() {
        XCTAssertEqual(CaptionError.videoUnavailable.errorDescription,
                       "视频不可用或已删除")
    }

    func testRequiresLoginMessage() {
        XCTAssertEqual(CaptionError.requiresLogin.errorDescription,
                       "视频要求登录（年龄限制或会员）,iOS 无法满足,请推送到桌面端")
    }

    func testNoCaptionsMessage() {
        XCTAssertEqual(CaptionError.noCaptions.errorDescription,
                       "该视频没有字幕,可推送到桌面端用 Whisper 转录")
    }

    func testNoEnglishCaptionsMessage() {
        XCTAssertEqual(CaptionError.noEnglishCaptions.errorDescription,
                       "该视频没有英文字幕")
    }

    func testTimedtextFetchFailedMessage() {
        XCTAssertEqual(CaptionError.timedtextFetchFailed(status: 404).errorDescription,
                       "字幕拉取失败 (HTTP 404),YouTube 可能临时拒绝服务")
    }

    func testParseFailedMessage() {
        XCTAssertEqual(CaptionError.parseFailed.errorDescription,
                       "字幕格式异常,请稍后重试")
    }

    func testEmptyResultMessage() {
        XCTAssertEqual(CaptionError.emptyResult.errorDescription,
                       "字幕解析结果为空")
    }
}
