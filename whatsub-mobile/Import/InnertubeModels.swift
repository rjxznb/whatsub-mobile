import Foundation

/// Decoded subset of the youtubei `/v1/player` response we care about.
/// Only fields the caption pipeline actually reads are modelled — most
/// of the response (streamingData, videoDetails, microformat, etc.)
/// is irrelevant for caption extraction and remains unparsed.
struct PlayerResponse: Decodable {
    let playabilityStatus: PlayabilityStatus
    let captions: CaptionsContainer?
}

struct PlayabilityStatus: Decodable {
    /// YouTube's terminology — values we observe in practice: "OK",
    /// "ERROR", "UNPLAYABLE", "LOGIN_REQUIRED", "AGE_VERIFICATION_REQUIRED",
    /// "LIVE_STREAM_OFFLINE". The extractor maps these to CaptionError
    /// cases in YouTubeCaptionExtractor.
    let status: String
}

struct CaptionsContainer: Decodable {
    let playerCaptionsTracklistRenderer: TracklistRenderer?
}

struct TracklistRenderer: Decodable {
    let captionTracks: [CaptionTrack]
}

struct CaptionTrack: Decodable {
    /// Signed URL where YouTube serves the actual timedtext payload.
    /// Append `&fmt=json3` to request the JSON format our parser
    /// already understands (see TimedtextParser.swift).
    let baseUrl: String
    /// BCP-47 language code, sometimes with region suffix ("en", "en-US",
    /// "en-GB", "es", "ja", etc.). We treat anything starting with "en"
    /// as English.
    let languageCode: String
    /// "asr" for auto-generated, absent for manual. Manual is preferred
    /// because it's usually creator-authored and higher quality.
    let kind: String?
}

/// Pick the best English caption track from a YouTube response.
///
/// Priority order (spec §4.2 step 4):
///   1. English-language with no `kind` (manual / creator-authored)
///   2. English-language with `kind == "asr"` (auto-generated)
///   3. nil — caller throws CaptionError.noEnglishCaptions
///
/// "English-language" means `languageCode.hasPrefix("en")` so en, en-US,
/// en-GB all match. The legacy plugin's behaviour matched only
/// `languageCode == "en"` and missed regional variants on some videos —
/// the prefix check fixes that.
func pickBestEnglishCaptionTrack(_ tracks: [CaptionTrack]) -> CaptionTrack? {
    if let manual = tracks.first(where: {
        $0.languageCode.hasPrefix("en") && $0.kind == nil
    }) {
        return manual
    }
    if let asr = tracks.first(where: {
        $0.languageCode.hasPrefix("en") && $0.kind == "asr"
    }) {
        return asr
    }
    return nil
}
