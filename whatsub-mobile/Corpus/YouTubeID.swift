import Foundation

/// Extract the 11-char video id from a YouTube watch / youtu.be URL.
/// Returns nil for non-YouTube URLs.
func extractYouTubeID(_ urlString: String) -> String? {
    guard let comps = URLComponents(string: urlString), let host = comps.host else { return nil }
    if host.contains("youtu.be") {
        let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }
    if host.contains("youtube.com") {
        return comps.queryItems?.first(where: { $0.name == "v" })?.value
    }
    return nil
}
