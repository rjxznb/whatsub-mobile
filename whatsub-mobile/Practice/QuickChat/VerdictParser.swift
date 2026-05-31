import Foundation

/// Streaming sentinel scanner. Consumes assistant chunks one at a time and
/// returns: (a) the portion safe to forward as dialog (and feed TTS), and
/// (b) — once `<<<VERDICT>>>...<<<END>>>` has been seen in full — the parsed
/// TurnVerdict.
///
/// Why streaming: spec §6.2 wants TTS to start playing the first sentence
/// before the verdict block arrives, so we can't wait for the full response.
///
/// Holdback: we keep only the longest suffix of the dialog buffer that is also
/// a prefix of the start sentinel. Anything shorter than that cannot possibly
/// be the beginning of the sentinel, so it's safe to flush immediately.
/// This is smarter than the naive "hold back sentinelLength-1 chars" approach,
/// which would stall dialog output unnecessarily.
struct VerdictParser {
    struct Output {
        let dialogChunk: String                 // safe-to-display text from THIS feed
        let completedVerdict: TurnVerdict?      // non-nil exactly once per turn (or never)
    }

    private static let startSentinel = "<<<VERDICT>>>"
    private static let endSentinel   = "<<<END>>>"

    private enum Phase { case dialog, verdict, done }
    private var phase: Phase = .dialog
    private var dialogBuffer = ""           // potential-sentinel-prefix carryover
    private var verdictBuffer = ""

    /// Feed a chunk; get back what's safe to render + maybe a finished verdict.
    mutating func feed(_ chunk: String) -> Output {
        switch phase {
        case .done:
            return Output(dialogChunk: "", completedVerdict: nil)

        case .verdict:
            verdictBuffer += chunk
            if let endRange = verdictBuffer.range(of: Self.endSentinel) {
                let jsonText = String(verdictBuffer[..<endRange.lowerBound])
                phase = .done
                let parsed = parseVerdict(jsonText)
                return Output(dialogChunk: "", completedVerdict: parsed)
            }
            return Output(dialogChunk: "", completedVerdict: nil)

        case .dialog:
            dialogBuffer += chunk
            // If the start sentinel is fully present, split there.
            if let startRange = dialogBuffer.range(of: Self.startSentinel) {
                let before = String(dialogBuffer[..<startRange.lowerBound])
                let after  = String(dialogBuffer[startRange.upperBound...])
                dialogBuffer = ""
                phase = .verdict
                // Recurse to handle the remainder, which may already contain
                // the end sentinel.
                let tail = self.feed(after)
                return Output(
                    dialogChunk: before + tail.dialogChunk,   // tail.dialogChunk is "" here
                    completedVerdict: tail.completedVerdict
                )
            }

            // No full sentinel yet. Find the longest suffix of the buffer that
            // is simultaneously a prefix of startSentinel — we must hold those
            // chars back in case the sentinel is being split across chunks.
            // Everything else is safe to flush.
            let holdback = longestSentinelPrefixSuffix(of: dialogBuffer)
            let safeCount = dialogBuffer.count - holdback
            let safeEnd   = dialogBuffer.index(dialogBuffer.startIndex, offsetBy: safeCount)
            let safe      = String(dialogBuffer[..<safeEnd])
            dialogBuffer  = String(dialogBuffer[safeEnd...])
            return Output(dialogChunk: safe, completedVerdict: nil)
        }
    }

    /// Flush at end-of-stream. If we were still in `.dialog` and the partial
    /// buffer didn't turn into a sentinel, it's plain dialog after all.
    mutating func finish() -> Output {
        switch phase {
        case .dialog:
            let leftover = dialogBuffer
            dialogBuffer = ""
            phase = .done
            return Output(dialogChunk: leftover, completedVerdict: nil)
        case .verdict, .done:
            // No closing sentinel = malformed. Per spec §6.4: treat as "no
            // verdict", not an error.
            phase = .done
            return Output(dialogChunk: "", completedVerdict: nil)
        }
    }

    // ---- private helpers ----

    /// Returns the length of the longest suffix of `s` that is also a prefix
    /// of `startSentinel`. This is the minimum we must hold back to avoid
    /// prematurely flushing the start of a split sentinel.
    private func longestSentinelPrefixSuffix(of s: String) -> Int {
        let sentinel = Self.startSentinel
        let maxLen   = min(s.count, sentinel.count - 1)
        guard maxLen > 0 else { return 0 }
        for n in stride(from: maxLen, through: 1, by: -1) {
            let suffix    = String(s.suffix(n))
            let sentPrefix = String(sentinel.prefix(n))
            if suffix == sentPrefix { return n }
        }
        return 0
    }

    private func parseVerdict(_ jsonText: String) -> TurnVerdict? {
        guard let data = jsonText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TurnVerdict.self, from: data)
    }
}
