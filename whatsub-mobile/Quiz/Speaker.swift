import AVFoundation

/// Forwards AVSpeechSynthesizer word-timing callbacks to LyricTicker so the
/// in-app "Apple Music lyrics" view can sync highlighting to the audio.
/// Singleton because the Speaker's synth is a `static let`.
private final class SpeakerLyricDelegate: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeakerLyricDelegate()

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            LyricTicker.shared.beginUtterance(utterance.speechString)
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        Task { @MainActor in
            LyricTicker.shared.setWordRange(characterRange)
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            LyricTicker.shared.endUtterance()
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            LyricTicker.shared.endUtterance()
        }
    }
}

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
    private static let synth: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.delegate = SpeakerLyricDelegate.shared
        return s
    }()
    private static let femaleNames = [
        "Samantha", "Ava", "Allison", "Susan", "Nicky", "Joelle",
        "Karen", "Moira", "Tessa", "Serena", "Fiona", "Zoe",
    ]

    /// UserDefaults key for the optional pinned voice identifier. Set by
    /// VoiceSettingsView. When nil (empty string), Speaker auto-picks the best
    /// installed voice.
    static let pinnedVoiceDefaultsKey = "speaker.pinned-voice-identifier.v1"

    /// True when the user has pinned the Piper LJSpeech voice in VoiceSettings.
    static var isPiperPinned: Bool {
        UserDefaults.standard.string(forKey: pinnedVoiceDefaultsKey) == piperLjspeechIdentifier
    }

    /// Quiz-card flow (unchanged contract): interrupts any in-flight speech.
    static func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isPiperPinned, PiperTTS.shared.canSpeak {
            PiperTTS.shared.speak(trimmed, interrupt: true)
            return
        }
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
        if locale.hasPrefix("en"), isPiperPinned, PiperTTS.shared.canSpeak {
            PiperTTS.shared.speak(trimmed, interrupt: false)
            return
        }
        configureSessionIfNeeded()
        synth.speak(makeUtterance(trimmed, locale: locale, rate: rate))
    }

    /// True while any utterance is being spoken or is queued.
    static var isSpeaking: Bool { synth.isSpeaking || PiperTTS.shared.isSpeaking }

    /// Stop current speech without releasing the audio session. Safe to call
    /// repeatedly during a session (e.g. from vm.pause() on scenePhase changes).
    /// Calls stopSpeaking unconditionally — AVSpeechSynthesizer.isSpeaking has
    /// reported flakiness where it returns false while queued utterances still play.
    static func stop() {
        synth.stopSpeaking(at: .immediate)
        PiperTTS.shared.stop()
        Task { @MainActor in LyricTicker.shared.reset() }
    }

    /// Stop speech AND release the audio session. Call this only when the
    /// QuickChat session is ending permanently (confirmed close) — releasing
    /// the session early in a session breaks subsequent TTS playback because
    /// iOS won't immediately accept a reactivation after a deactivation with
    /// .notifyOthersOnDeactivation.
    static func releaseSession() {
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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

    /// Pick the best available voice for `locale`, preferring quality tier
    /// (premium > enhanced > default). For English we additionally prefer the
    /// known-female-name list (Samantha, Ava, ...) within each quality tier so
    /// the timbre stays consistent with what users have heard since v1.
    ///
    /// Premium voices were added in iOS 16+ and use neural TTS — substantially
    /// more natural than the default Samantha. They are NOT pre-installed; the
    /// user must download them once via Settings → Accessibility → Spoken
    /// Content → Voices → English → tap a voice marked "Premium" → Download.
    /// `hasPremiumEnglishVoice` lets the QuickChatView surface a one-time hint
    /// if no premium voice is found locally.
    private static func pickVoice(locale: String) -> AVSpeechSynthesisVoice? {
        // 1. If the user has pinned a specific voice in 我的 → 语音设置 AND
        //    that voice is still installed AND its language matches the requested
        //    locale prefix, prefer it over auto-pick.
        let pinnedId = UserDefaults.standard.string(forKey: pinnedVoiceDefaultsKey) ?? ""
        if !pinnedId.isEmpty,
           let pinned = AVSpeechSynthesisVoice(identifier: pinnedId),
           pinned.language.hasPrefix(locale.prefix(2)) {
            return pinned
        }

        // 2. Otherwise: auto-pick logic (premium → enhanced → default).
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let matching = allVoices.filter { $0.language.hasPrefix(locale.prefix(2)) }
        guard !matching.isEmpty else { return AVSpeechSynthesisVoice(language: locale) }

        // Quality tiers, best first.
        let tiers: [AVSpeechSynthesisVoiceQuality] = [.premium, .enhanced, .default]

        if locale.hasPrefix("en") {
            // English: within each quality tier, prefer the known female names.
            for tier in tiers {
                let inTier = matching.filter { $0.quality == tier }
                // First scan for our preferred names in en-US specifically.
                for name in femaleNames {
                    if let v = inTier.first(where: { $0.name == name && $0.language == "en-US" }) { return v }
                }
                // Then any en-US in this tier.
                if let v = inTier.first(where: { $0.language == "en-US" }) { return v }
                // Then any English variant.
                if let v = inTier.first { return v }
            }
        } else {
            // Non-English: just pick best-quality voice for the locale.
            for tier in tiers {
                if let v = matching.first(where: { $0.quality == tier && $0.language == locale }) { return v }
                if let v = matching.first(where: { $0.quality == tier }) { return v }
            }
        }
        return matching.first ?? AVSpeechSynthesisVoice(language: locale)
    }

    /// Returns all installed English TTS voices, sorted by quality tier
    /// (premium → enhanced → default), then by language code, then by name.
    /// Used by VoiceSettingsView.
    static func availableEnglishVoices() -> [AVSpeechSynthesisVoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return voices.sorted { a, b in
            let qa = qualityRank(a.quality)
            let qb = qualityRank(b.quality)
            if qa != qb { return qa < qb }
            if a.language != b.language { return a.language < b.language }
            return a.name < b.name
        }
    }

    private static func qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium: return 0
        case .enhanced: return 1
        default: return 2
        }
    }

    /// True iff at least one English voice with `.premium` or `.enhanced`
    /// quality is installed. Used by QuickChatView to decide whether to
    /// surface a one-time tip about downloading premium voices.
    static var hasPremiumEnglishVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language.hasPrefix("en") && ($0.quality == .premium || $0.quality == .enhanced)
        }
    }
}
