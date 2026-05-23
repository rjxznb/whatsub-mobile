import Foundation

/// Shared store between the app + the Share Extension (separate processes).
/// Requires the App Group entitlement `group.cc.eversay.whatsub.mobile` on
/// both targets, registered in the Apple Developer portal.
enum AppGroup {
    static let suiteName = "group.cc.eversay.whatsub.mobile"
    private static let pendingKey = "pendingImportURL"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func setPendingImportURL(_ url: String) { defaults?.set(url, forKey: pendingKey) }
    static func pendingImportURL() -> String? { defaults?.string(forKey: pendingKey) }
    static func clearPendingImportURL() { defaults?.removeObject(forKey: pendingKey) }
}

/// First http(s) URL found in a string (share sheets sometimes deliver the URL
/// inside surrounding text).
func firstURL(in text: String) -> String? {
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(text.startIndex..., in: text)
    guard let match = detector?.firstMatch(in: text, range: range),
          let r = Range(match.range, in: text) else { return nil }
    let s = String(text[r])
    return s.hasPrefix("http") ? s : nil
}
