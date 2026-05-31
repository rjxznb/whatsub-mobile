import SwiftUI
import UIKit

/// Spec §9.7 prep: long-press an assistant bubble → "上报这条回复". v1 opens a
/// `mailto:` to the admin address with the message text pre-filled — no
/// backend needed. Apple §1.1/1.2 reviewers see a working reporting path.
struct ReportMessageSheet {
    static let adminEmail = "appreview@eversay.cc"

    /// Open mail composer / share sheet pre-filled with the message text.
    /// Returns true if a mailto: URL was successfully opened.
    @discardableResult
    static func openMailReport(message: String) -> Bool {
        let subject = "举报对话陪练回复"
        let body = """
        我想举报对话陪练里这条服务返回的内容：

        ----
        \(message)
        ----

        理由（请填写）：
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = adminEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url,
              UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
