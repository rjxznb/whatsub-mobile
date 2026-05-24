import Foundation

enum APIError: Error, Equatable {
    case network(String)         // transport failure (no connection, timeout, TLS)
    case unauthorized            // 401 — session expired/invalid
    case server(Int, String?)    // non-2xx with a parsed `error` string if any
    case decoding(String)        // response didn't match the expected shape
    case badInput(String)        // client-side validation (e.g. bad email)
    case quotaExceeded(used: Int, limit: Int)   // 403 from library sync/push — over the OSS-video cap

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
            case "quota_exceeded": return "云端视频已达上限，先在 Library 删一个，或购买授权解锁更多"
            default: return "服务器错误（\(code)）"
            }
        case .decoding(let detail):
            return "数据解析失败：\(detail)"
        case .badInput(let detail):
            return detail
        case .quotaExceeded(let used, let limit):
            return "云端视频已达上限（\(used)/\(limit)）"
        }
    }
}
