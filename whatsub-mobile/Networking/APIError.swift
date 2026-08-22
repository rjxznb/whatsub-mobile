import Foundation

enum APIError: Error, Equatable {
    case network(String)         // transport failure (no connection, timeout, TLS)
    case unauthorized            // 401 — session expired/invalid
    case server(Int, String?)    // non-2xx with a parsed `error` string if any
    case decoding(String)        // response didn't match the expected shape
    case badInput(String)        // client-side validation (e.g. bad email)
    case quotaExceeded(used: Int, limit: Int)   // 403 from library sync/push — over the OSS-video cap
    /// Stable server error code for Token top-up flows. The Chinese message
    /// remains presentation-only; callers branch on the code.
    case tokenTopup(String)
    /// 429 from /api/license/auth/{send,verify}-code. Wire shape:
    ///   { error: "rate_limited",
    ///     scope: "email-minute" | "email-hour" | "ip-hour",
    ///     retryAfterSec: <int>,
    ///     message: <zh-Hans> }
    /// `retryAfterSec` is also echoed in the `Retry-After` header.
    case rateLimited(scope: String, retryAfterSec: Int, message: String)

    /// Chinese message for display in the UI. Warmth pass 2026-06-07 — every
    /// branch should sound like a friend telling you what happened + how to
    /// fix it, not a stack trace. NEVER include raw error bodies, code dumps,
    /// or English error keys (e.g. "license_blocked") in the output string.
    var chinese: String {
        switch self {
        case .network(let detail):
            return "网络好像断开了，检查一下连接再试。（\(detail)）"
        case .unauthorized:
            return "登录信息过期了，重新登录一下就好。"
        case .server(let code, let err):
            switch err {
            case "invalid_email": return "邮箱格式好像不太对，再检查一下。"
            case "invalid_input": return "信息有点不对，再核对一下。"
            case "no_code": return "先获取一次验证码吧。"
            case "wrong_code": return "验证码不对，再确认一下。"
            case "too_many_attempts": return "尝试次数有点多了，重新获取一次验证码吧。"
            // LLM-policy 4xx — same shape the relay returns. Order matters:
            // "quota_exceeded" exists on /library/sync (413) AND /llm/v1 (429),
            // so the 429 branch must come BEFORE the generic library branch.
            case "license_blocked":
                return "你目前是「网站买断」用户，托管 AI 需要订阅 Pro；也可以去「我的 → LLM 设置」使用自己的 API Key。"
            case "free_used_up":
                return "免费 AI 体验额度已经用完啦。订阅 Pro 后可以继续解析，已下载的字幕和进度会保留。"
            case "trial_used_up":
                return "桌面端试用额度已经用完。订阅 Pro 即可继续使用 AI 功能。"
            case "quota_exceeded" where code == 429:
                return "本月 AI 额度已经用完。Pro 用户可以购买 Token 加量包，或等下月额度重置。"
            case "quota_exceeded":
                return "云端视频已经满了。先到 Library 删一个，或者升级 Pro 解锁更多空间。"
            default: return "服务器错误（\(code)）"
            }
        case .decoding(let detail):
            return "解析返回数据时出了点状况，再试一次试试。（\(detail)）"
        case .badInput(let detail):
            return detail
        case .quotaExceeded(let used, let limit):
            return "云端视频已经满了（\(used)/\(limit)）。先到 Library 删一个，或升级 Pro 解锁更多空间。"
        case .tokenTopup(let code):
            switch code {
            case "topup_requires_pro": return "只有有效 Pro 用户可以购买 Token 加量包。"
            case "topup_product_invalid": return "这个 Token 加量包暂时不可用。"
            case "topup_account_mismatch": return "这笔交易与当前 whatSub 账号不匹配。"
            case "order_not_found": return "充值订单不存在或已失效。"
            case "alipay_unavailable": return "支付服务暂时不可用，请稍后重试。"
            default: return "Token 加量包暂时无法完成，请稍后重试。"
            }
        case .rateLimited(_, _, let message):
            // Server-supplied Chinese message already accounts for scope.
            return message
        }
    }
}
