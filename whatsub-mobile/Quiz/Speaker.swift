import AVFoundation

/// English / Chinese TTS using `AVSpeechSynthesizer`. Two entry points:
///
/// - `speak(_:)`            — Quiz word card; reads a short English phrase
///                            in a known female en-US voice (Samantha
///                            preferred). Behavior unchanged from v1.
/// - `enqueue(_:locale:rate:)` — QuickChat sentence-by-sentence streaming.
///                            Caller supplies locale (defaults en-US) and
///                            rate (defaults to AVDefault). Queues
///                            utterances rather than stopping prior speech,
///                            so the LLM's first sentence keeps playing
///                            while the next streams in.
///
/// Spec §6.3 (v1 single-language en-US after spike result; bilingual routing
/// deferred to v1.1 per §12).
enum Speaker {
    private static let synth = AVSpeechSynthesizer()
    private static let femaleNames = [
        "Samantha", "Ava", "Allison", "Susan", "Nicky", "Joelle",
        "Karen", "Moira", "Tessa", "Serena", "Fiona", "Zoe",
    ]

    /// Quiz-card flow (unchanged contract): interrupts any in-flight speech.
    static func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        configureSessionIfNeeded()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synth.speak(makeUtterance(trimmed, locale: "en-US", rate: AVSpeechUtteranceDefaultSpeechRate * 0.95))
    }

    /// QuickChat streaming flow: queues utterances so sentence-by-sentence
    /// feeding plays back contiguously. Does NOT interrupt prior speech.
    static func enqueue(_ text: String, locale: String = "en-US",
                       rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        configureSessionIfNeeded()
        synth.speak(makeUtterance(trimmed, locale: locale, rate: rate))
    }

    /// Stop everything (called when QuickChat ends, user pauses, or the
    /// AVAudioSession is interrupted).
    static func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    // ---- internals ----

    private static func configureSessionIfNeeded() {
        // Audible even with the silent switch on, mixing with any background audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    private static func makeUtterance(_ text: String, locale: String, rate: Float) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        u.voice = pickVoice(locale: locale)
        return u
    }

    private static func pickVoice(locale: String) -> AVSpeechSynthesisVoice? {
        if locale.hasPrefix("en") {
            let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            for name in femaleNames {
                if let v = english.first(where: { $0.name == name && $0.language == "en-US" }) { return v }
            }
            for name in femaleNames {
                if let v = english.first(where: { $0.name == name }) { return v }
            }
        }
        return AVSpeechSynthesisVoice(language: locale)
    }
}
