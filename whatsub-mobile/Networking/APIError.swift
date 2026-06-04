import Foundation

enum APIError: Error, Equatable {
    case network(String)         // transport failure (no connection, timeout, TLS)
    case unauthorized            // 401 — session expired/invalid
    case server(Int, String?)    // non-2xx with a parsed `error` string if any
    case decoding(String)        // response didn't match the expected shape
    case badInput(String)        // client-side validation (e.g. bad email)
    case quotaExceeded(used: Int, limit: Int)   // 403 from library sync/push — over the OSS-video cap
    /// 429 from /api/license/auth/{send,verify}-code. Wire shape:
    ///   { error: "rate_limited",
    ///     scope: "email-minute" | "email-hour" | "ip-hour",
    ///     retryAfterSec: <int>,
    ///     message: <zh-Hans> }
    /// `retryAfterSec` is also echoed in the `Retry-After` header.
    case rateLimited(scope: String, retryAfterSec: Int, message: String)

    /// Chinese message for display in the UI.
    var chinese: String {
        switch self {
        case .network(let detail):
            return "网络连接失败：\(detail)"
        case .unauthorized:
            return "登录已过期，请重新登录"
        case .server(let code, let err):
            switch err {
            case "invalid_email": return "邮箱格式不对"
            case "invalid_input": return "输入有误"
            case "no_code": return "请先获取验证码"
            case "wrong_code": return "验证码错误"
            case "too_many_attempts": return "尝试次数过多，请重新获取验证码"
            // LLM relay-specific (2026-06-04). Backend distinguishes these
            // so the UI can offer the right next step instead of a generic
            // "服务器错误". Order matters — "quota_exceeded" exists on both
            // /library/sync (413) and /llm/v1 (429); the 429 branch must
            // come BEFORE the generic library line below.
            case "license_blocked":
                return "你已购买永久网站授权（¥59.9 买断），按现行政策需 BYOK 自填 LLM key，或单独订阅 Pro 才能用 whatsub 托管 LLM。下方关闭「使用 whatsub 托管」即可改用自己的 key。"
            case "free_used_up":
                return "免费体验额度（200K tokens）已用完。请关闭 toggle 走 BYOK，或升级 Pro 解锁完整月度配额。"
            case "trial_used_up":
                return "桌面试用额度已用完，请升级 Pro 继续使用。"
            case "quota_exceeded" where code == 429:
                return "本月 LLM 额度已用完，下月 1 日重置或升级配额。"
            case "quota_exceeded": return "云端视频已达上限，先在 Library 删一个，或购买授权解锁更多"
            default: return "服务器错误（\(code)）"
            }
        case .decoding(let detail):
            return "数据解析失败：\(detail)"
        case .badInput(let detail):
            return detail
        case .quotaExceeded(let used, let limit):
            return "云端视频已达上限（\(used)/\(limit)）"
        case .rateLimited(_, _, let message):
            // Server-supplied Chinese message already accounts for scope.
            return message
        }
    }
}
