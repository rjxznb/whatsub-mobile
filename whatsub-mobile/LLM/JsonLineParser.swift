import Foundation

/// Streaming JSON-Lines parser. Mirrors `whatsub-releases/Get_Video/client/
/// src/llm/streamingJson.ts` — buffers incoming text, splits on `\n`, and
/// fires `handle` on each complete `{ ... }` line.
///
/// **Why**: DeepSeek v4 reasoning models (and the V4 family in general)
/// emit very long structured outputs that overflow a single non-stream
/// chat completion's response size + max_tokens budget. Streaming +
/// per-line parsing lets us:
///   1. Receive the first cue's translation immediately (~1s) instead of
///      waiting for the full 50-cue batch.
///   2. Avoid the "burn max_tokens on reasoning trace, content empty"
///      failure mode entirely — partial JSONL output still yields
///      finished cues we can keep.
///   3. Tolerate provider-side schema variants (content vs reasoning_content)
///      because the SSE chunk reader just concatenates whatever text
///      delta the chunks carry — wherever the provider chooses to emit it.
///
/// Lines that aren't a complete `{...}` JSON object are silently dropped
/// (blank lines, prose preamble, malformed cues mid-stream). The desktop
/// JsonLineParser does the same; the strict parser would tank usability
/// since DeepSeek occasionally interleaves "Now I'll output the next
/// cue:" text in BYOK mode.
final class JsonLineParser {
    private var buffer: String = ""

    /// Feed the next streamed text chunk. For each complete line that
    /// parses to a JSON object, calls `handle` with the parsed object.
    func feed(_ chunk: String, handle: (Any) -> Void) {
        buffer += chunk
        // Split on \n but keep the trailing partial line for the next feed.
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[..<newlineRange.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
            handleLine(line, handle: handle)
        }
    }

    /// Drain whatever is left in the buffer. Call once at end-of-stream
    /// in case the LLM omitted a trailing newline (DeepSeek sometimes does).
    func flush(_ handle: (Any) -> Void) {
        if !buffer.isEmpty {
            handleLine(buffer, handle: handle)
            buffer.removeAll()
        }
    }

    private func handleLine(_ line: String, handle: (Any) -> Void) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return
        }
        handle(obj)
    }
}
