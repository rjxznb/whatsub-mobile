import Foundation

/// Splits a stream of text chunks into complete sentences, useful for feeding
/// AVSpeechSynthesizer one sentence at a time so TTS starts before the LLM
/// has finished. Spec §6.3 "流式 TTS 切句喂".
///
/// Terminators: '.', '?', '!', or any newline ('\n', '\r'), plus Chinese/Japanese
/// full-width equivalents '。' '？' '！' '．'. Whitespace-only fragments are dropped.
/// flush() returns whatever's still buffered.
///
/// Chinese terminators are included so a Chinese scene-setting paragraph (which the
/// LLM might emit before the English dialogue) emits on its own boundary instead of
/// buffering until the next English '.', which would feed a large mixed Chinese+English
/// string to the en-US TTS voice — causing the utterance to go silent.
struct SentenceChunker {
    private var buffer = ""
    // Chinese full-width punctuation included so Chinese sentences emit on
    // their own boundary instead of buffering until the next English '.'.
    // (Otherwise a Chinese paragraph fed into en-US TTS Samantha goes silent.)
    private static let terminators: Set<Character> = [
        ".", "?", "!", "\n", "\r",       // ASCII
        "。", "？", "！", "．",            // Chinese / Japanese full-width
    ]

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
