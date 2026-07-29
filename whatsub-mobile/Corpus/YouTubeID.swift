import Foundation

/// Extract the 11-char video id from a YouTube watch / youtu.be / shorts / embed URL.
/// Returns nil for non-YouTube URLs.
func extractYouTubeID(_ urlString: String) -> String? {
    VideoSource.youtubeVideoID(from: urlString)
}
