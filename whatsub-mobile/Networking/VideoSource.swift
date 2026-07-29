import Foundation

/// Which platform a library/import URL belongs to. Drives import routing
/// (YouTube has a client-side caption path; everything else → desktop queue)
/// and the playback fallback guard.
enum VideoSource {
    case youtube
    case bilibili
    case other

    private static let officialYouTubeHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "youtu.be"
    ]

    /// Classify by URL host.
    static func from(url: String) -> VideoSource {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return .other }
        if officialYouTubeHosts.contains(host) { return .youtube }
        if host.contains("bilibili.com") || host.contains("b23.tv") { return .bilibili }
        return .other
    }

    /// Parse a validated 11-character video id from the exact YouTube hosts
    /// supported by the product. Substring/lookalike hosts are rejected.
    static func youtubeVideoID(from url: String) -> String? {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              officialYouTubeHosts.contains(host) else { return nil }

        let pathParts = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let candidate: String?

        if host == "youtu.be" {
            candidate = pathParts.count == 1 ? pathParts[0] : nil
        } else if pathParts.count >= 2,
                  ["shorts", "embed", "live", "v"].contains(pathParts[0]) {
            candidate = pathParts[1]
        } else if pathParts.isEmpty || pathParts == ["watch"] {
            candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
        } else {
            candidate = nil
        }

        guard let candidate, isLikelyYouTubeId(candidate) else { return nil }
        return candidate
    }

    /// Returns a canonical watch URL only when the strict source parser agrees
    /// with the entry's recorded YouTube id.
    static func canonicalYouTubeURL(from sourceURL: String, expectedVideoID: String) -> String? {
        guard let verifiedID = youtubeVideoID(from: sourceURL),
              verifiedID == expectedVideoID else { return nil }
        return "https://www.youtube.com/watch?v=\(verifiedID)"
    }

    /// A real YouTube video id is exactly 11 chars of [A-Za-z0-9_-]. Bilibili BV
    /// ids (12 chars, "BV…") and fallback hashes ("u_…") fail this — so we never
    /// feed a non-YouTube id to the YouTube embed.
    static func isLikelyYouTubeId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
