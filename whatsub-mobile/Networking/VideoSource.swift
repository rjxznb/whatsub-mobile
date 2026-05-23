import Foundation

/// Which platform a library/import URL belongs to. Drives import routing
/// (YouTube has a client-side caption path; everything else → desktop queue)
/// and the playback fallback guard.
enum VideoSource {
    case youtube
    case bilibili
    case other

    /// Classify by URL host.
    static func from(url: String) -> VideoSource {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return .other }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("bilibili.com") || host.contains("b23.tv") { return .bilibili }
        return .other
    }

    /// A real YouTube video id is exactly 11 chars of [A-Za-z0-9_-]. Bilibili BV
    /// ids (12 chars, "BV…") and fallback hashes ("u_…") fail this — so we never
    /// feed a non-YouTube id to the YouTube embed.
    static func isLikelyYouTubeId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
