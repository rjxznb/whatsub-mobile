import Foundation

/// Splits a stream of text chunks into complete sentences, useful for feeding
/// AVSpeechSynthesizer one sentence at a time so TTS starts before the LLM
/// has finished. Spec §6.3 "流式 TTS 切句喂".
///
/// Terminators: '.', '?', '!', or any newline ('\n', '\r'). Whitespace-only
/// fragments are dropped. flush() returns whatever's still buffered.
struct SentenceChunker {
    private var buffer = ""
    private static let terminators: Set<Character> = [".", "?", "!", "\n", "\r"]

    mutating func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var out: [String] = []
        var current = ""
        for ch in buffer {
            if Self.terminators.contains(ch) {
                let isNewline = ch == "\n" || ch == "\r"
                let sentence: String
                if isNewline {
                    sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    sentence = (current + String(ch)).trimmingCharacters(in: .whitespaces)
                }
                if !sentence.isEmpty { out.append(sentence) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        buffer = current   // keep the partial sentence for next call
        return out
    }

    mutating func flush() -> [String] {
        let leftover = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return leftover.isEmpty ? [] : [leftover]
    }
}
