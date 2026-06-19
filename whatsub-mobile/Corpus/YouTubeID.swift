import Foundation

/// Extract the 11-char video id from a YouTube watch / youtu.be / shorts / embed URL.
/// Returns nil for non-YouTube URLs.
func extractYouTubeID(_ urlString: String) -> String? {
    guard let comps = URLComponents(string: urlString), let host = comps.host else { return nil }
    if host.contains("youtu.be") {
        let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }
    if host.contains("youtube.com") {
        let parts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
            return parts[1]
        }
        return comps.queryItems?.first(where: { $0.name == "v" })?.value
    }
    return nil
}
