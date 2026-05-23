import Foundation

/// One subtitle cue parsed from a YouTube timedtext json3 response.
/// Mirror of the plugin's `Cue` (web-plugin/src/sw/transcripts/parseTimedtextJson3.ts).
struct SpikeCue: Equatable {
    let idx: Int
    let time: Double   // seconds
    let end: Double    // seconds
    let text: String
}

/// Parse a YouTube `/api/timedtext?...&fmt=json3` body into cues.
/// json3 shape: { events: [ { tStartMs, dDurationMs, segs: [{ utf8 }] } ] }.
/// Blank/whitespace-only events are dropped (matches the plugin).
func parseTimedtextJson3(_ data: Data) -> [SpikeCue] {
    guard
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let events = root["events"] as? [[String: Any]]
    else { return [] }

    var cues: [SpikeCue] = []
    var idx = 0
    for e in events {
        guard let segs = e["segs"] as? [[String: Any]] else { continue }
        let text = segs.map { ($0["utf8"] as? String) ?? "" }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let startMs = (e["tStartMs"] as? NSNumber)?.doubleValue ?? 0
        let durMs = (e["dDurationMs"] as? NSNumber)?.doubleValue ?? 0
        let start = startMs / 1000.0
        cues.append(SpikeCue(idx: idx, time: start, end: start + durMs / 1000.0, text: text))
        idx += 1
    }
    return cues
}
