import AVFoundation

/// Reads the quiz prompt aloud in an English female voice.
///
/// iOS 16 has no `AVSpeechSynthesisVoice.gender` (that landed in iOS 17), so we
/// pick a known female English voice by name. The en-US system default is
/// Samantha (female), which is also the final fallback.
enum Speaker {
    private static let synth = AVSpeechSynthesizer()

    /// Apple's English female voices, in preference order.
    private static let femaleNames = [
        "Samantha", "Ava", "Allison", "Susan", "Nicky", "Joelle",
        "Karen", "Moira", "Tessa", "Serena", "Fiona", "Zoe",
    ]

    static func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Audible even with the silent switch on, mixing with any background audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: trimmed)
        u.voice = femaleEnglishVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95 // a touch slower for learning
        synth.speak(u)
    }

    private static func femaleEnglishVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        // Prefer a known female name on en-US, then on any English locale, then
        // the en-US system default (Samantha, female).
        for name in femaleNames {
            if let v = english.first(where: { $0.name == name && $0.language == "en-US" }) { return v }
        }
        for name in femaleNames {
            if let v = english.first(where: { $0.name == name }) { return v }
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}
