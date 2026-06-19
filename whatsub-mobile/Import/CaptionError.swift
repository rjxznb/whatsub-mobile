import Foundation

/// All failure paths the iOS-native YouTube caption extractor can surface.
/// Replaces the legacy WKWebView-based `CaptionExtractor.CaptionError` which
/// only carried `.timeout`, `.emptyResult`, and `.requiresLogin`.
///
/// Message strings are sourced verbatim from
/// `docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md` §6.2
/// and exposed to the user via `LocalizedError.errorDescription`. The
/// ImportView failure card renders them inline; the
/// CaptionDiagnosticsSheet button surfaces the per-step debug log
/// separately.
enum CaptionError: Error, LocalizedError {
    // Legacy WKWebView-based extractor cases (preserved for compatibility)
    case timeout
    // New iOS-native Innertube-based extractor cases
    case network(URLError)
    case http(status: Int)
    case videoUnavailable
    case requiresLogin
    case noCaptions
    case noEnglishCaptions
    case timedtextFetchFailed(status: Int)
    case parseFailed
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "未捕获到字幕。可能是 YouTube 对本会话反爬升级了，或视频本身没有英文字幕。点「查看诊断」看挂在哪一步，或「推送到桌面端」让 Whisper 转录。"
        case .network:
            return "网络错误,请检查 VPN 或网络连接"
        case .http(let status):
            return "YouTube 接口暂时不可用 (HTTP \(status))"
        case .videoUnavailable:
            return "视频不可用或已删除"
        case .requiresLogin:
            return "视频要求登录（年龄限制或会员）,iOS 无法满足,请推送到桌面端"
        case .noCaptions:
            return "该视频没有字幕,可推送到桌面端用 Whisper 转录"
        case .noEnglishCaptions:
            return "该视频没有英文字幕"
        case .timedtextFetchFailed(let status):
            return "字幕拉取失败 (HTTP \(status)),YouTube 可能临时拒绝服务"
        case .parseFailed:
            return "字幕格式异常,请稍后重试"
        case .emptyResult:
            return "字幕解析结果为空"
        }
    }
}
