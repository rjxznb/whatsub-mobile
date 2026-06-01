import Foundation

/// Centralized tracker for the currently-being-spoken AI sentence + active
/// word range. Published from MainActor so SwiftUI can bind directly.
///
/// Apple TTS path: Speaker's AVSpeechSynthesizerDelegate calls
///   beginUtterance / setWordRange / endUtterance, giving real word timing.
///
/// Piper TTS path: no per-word callback, so PiperTTS.playFile invokes
///   simulateWords(in:duration:) which evenly divides the total play time
///   into per-word steps via a Timer.
@MainActor
final class LyricTicker: ObservableObject {
    static let shared = LyricTicker()

    @Published private(set) var currentSentence: String = ""
    @Published private(set) var currentWordRange: NSRange?

    private var simulationTimer: Timer?

    private init() {}

    /// Apple TTS path: utterance is about to start.
    func beginUtterance(_ text: String) {
        simulationTimer?.invalidate()
        simulationTimer = nil
        currentSentence = text
        currentWordRange = nil
    }

    /// Apple TTS path: per-word callback.
    func setWordRange(_ range: NSRange) {
        currentWordRange = range
    }

    /// Apple TTS path: utterance done.
    func endUtterance() {
        currentWordRange = nil
        // Keep currentSentence so the bubble doesn't pop; next utterance overwrites.
    }

    /// Piper TTS path: estimate word timings by even division.
    /// Words split on whitespace; non-word punctuation stays attached to its word.
    func simulateWords(in text: String, duration: TimeInterval) {
        simulationTimer?.invalidate()
        currentSentence = text
        currentWordRange = nil
        let words = Self.tokenize(text)
        guard !words.isEmpty, duration > 0 else { return }
        let perWord = max(0.05, duration / Double(words.count))
        var idx = 0
        simulationTimer = Timer.scheduledTimer(withTimeInterval: perWord, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if idx >= words.count {
                    timer.invalidate()
                    self.currentWordRange = nil
                    return
                }
                self.currentWordRange = words[idx].range
                idx += 1
            }
        }
        // Schedule auto-clear after duration + a small grace.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.3) * 1_000_000_000))
            self.currentWordRange = nil
        }
    }

    /// Hard reset (e.g. user closes the session).
    func reset() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        currentSentence = ""
        currentWordRange = nil
    }

    // ---- tokenization helper ----

    struct Token: Equatable {
        let text: String
        let range: NSRange
    }

    /// Splits `text` into non-whitespace tokens with their NSRange in the
    /// original string. Public so the view can reuse it to render.
    static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "\\S+") else { return out }
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let m = match {
                out.append(Token(text: ns.substring(with: m.range), range: m.range))
            }
        }
        return out
    }
}
