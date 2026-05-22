import Foundation

struct HighlightRun: Equatable {
    let text: String
    let highlight: Bool
}

/// Slice `text` into runs alternating normal / highlight. Non-overlapping —
/// earliest-start highlight wins on collisions. Port of the desktop client's
/// splitForHighlights (client/src/components/VideoPlayer.tsx) so iOS highlights
/// match the desktop exactly.
func splitForHighlights(_ text: String, highlights: [String]) -> [HighlightRun] {
    let nonEmpty = highlights.filter { !$0.isEmpty }
    if nonEmpty.isEmpty { return [HighlightRun(text: text, highlight: false)] }

    let chars = Array(text)
    struct Match { let start: Int; let end: Int }
    var matches: [Match] = []
    for w in nonEmpty {
        if let range = text.range(of: w) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            matches.append(Match(start: start, end: end))
        }
    }
    matches.sort { $0.start < $1.start }
    var merged: [Match] = []
    var lastEnd = 0
    for m in matches where m.start >= lastEnd {
        merged.append(m); lastEnd = m.end
    }
    var runs: [HighlightRun] = []
    var cursor = 0
    for m in merged {
        if m.start > cursor {
            runs.append(HighlightRun(text: String(chars[cursor..<m.start]), highlight: false))
        }
        runs.append(HighlightRun(text: String(chars[m.start..<m.end]), highlight: true))
        cursor = m.end
    }
    if cursor < chars.count {
        runs.append(HighlightRun(text: String(chars[cursor...]), highlight: false))
    }
    return runs
}
