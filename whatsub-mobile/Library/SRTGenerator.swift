import Foundation

/// Generate SubRip (.srt) text from a list of Cue. The backend stores both
/// `analysis_json` (rich, programmatic) and `transcript_srt` (plain SRT,
/// for export / sharing / desktop SRT viewers). When the iOS editor saves
/// changes we have to regenerate both — there's no server-side SRT
/// derivation; the desktop pipeline produces both at sync time.
///
/// Format: standard SubRip
///   1
///   00:00:01,000 --> 00:00:04,500
///   English line
///   中文一行
///
///   2
///   00:00:04,500 --> 00:00:07,200
///   ...
///
/// Translation appears as a second text line under the English when
/// non-empty. Cues are emitted in argument order — the editor pre-sorts
/// by `cue.time` before calling, so this stays a pure formatter.
enum SRTGenerator {
    static func generate(from cues: [Cue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            let n = i + 1
            out += "\(n)\n"
            out += "\(formatTime(cue.time)) --> \(formatTime(cue.endTime))\n"
            out += "\(cue.text)\n"
            if !cue.translation.isEmpty {
                out += "\(cue.translation)\n"
            }
            out += "\n"
        }
        return out
    }

    /// 1.234 → "00:00:01,234". SubRip uses comma as decimal separator (per
    /// the original Marko Stojanović spec), not period — VLC and most
    /// SRT viewers tolerate both but the desktop client emits commas, so
    /// stay consistent.
    private static func formatTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000.0).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let s = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
