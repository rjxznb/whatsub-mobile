import Foundation
import AVFoundation

/// Pretrained-voice ID our Speaker uses for Piper LJSpeech English.
/// VoiceSettingsView pins this identifier; Speaker.isPiperPinned checks for it.
let piperLjspeechIdentifier = "whatsub.piper.ljspeech-en"

/// Wraps sherpa-onnx's offline TTS for the Piper LJSpeech English voice.
/// On first use, loads the ONNX model into a singleton SherpaOnnxOfflineTtsWrapper
/// (~1-3s on iPhone 12+). Subsequent generate() calls are fast (~500ms for a sentence).
/// Output PCM samples are written to a temp WAV file and played with AVAudioPlayer.
///
/// Thread safety: the SherpaOnnxOfflineTtsWrapper is not async. We invoke it from
/// a background queue and dispatch playback back to MainActor.
final class PiperTTS {
    static let shared = PiperTTS()

    private var ttsWrapper: SherpaOnnxOfflineTtsWrapper?
    private var loadAttempted = false
    private let loadQueue = DispatchQueue(label: "piper.tts.load", qos: .userInitiated)
    private let inferQueue = DispatchQueue(label: "piper.tts.infer", qos: .userInitiated)

    /// AVAudioPlayers for queued sentence playback. We retain them and let
    /// AVAudioPlayer's own delegate finish each before kicking the next.
    private var playbackQueue: [(url: URL, text: String)] = []
    private var currentPlayer: AVAudioPlayer?
    private let playerDelegate = PlayerDelegate()

    private init() {
        playerDelegate.owner = self
    }

    /// True iff model files are present on disk + espeak-ng-data bundle exists.
    var canSpeak: Bool {
        guard Self.modelDir != nil, Self.espeakDataPath != nil else { return false }
        return true
    }

    /// Loads the model (idempotent). Heavy first-call latency expected.
    /// Returns true if the wrapper is now available, false otherwise.
    func loadIfNeeded() -> Bool {
        if ttsWrapper != nil { return true }
        guard canSpeak, let dir = Self.modelDir else { return false }
        if loadAttempted, ttsWrapper == nil { return false }
        loadAttempted = true

        // Matcha-icefall LJSpeech (swapped in 2026-06-05 — was Piper
        // LJSpeech medium, user reported it sounded "平、不连读". Matcha
        // is a diffusion-based TTS with native prosody + liaison; the
        // SherpaOnnxOfflineTtsMatchaModelConfig takes an acoustic model
        // + vocoder pair instead of Piper's single .onnx).
        let acoustic = dir.appendingPathComponent("model-steps-3.onnx").path
        let vocoder = dir.appendingPathComponent("hifigan_v2.onnx").path
        let tokens = dir.appendingPathComponent("tokens.txt").path
        guard let espeak = Self.espeakDataPath else { return false }

        let matcha = sherpaOnnxOfflineTtsMatchaModelConfig(
            acousticModel: acoustic,
            vocoder: vocoder,
            lexicon: "",
            tokens: tokens,
            dataDir: espeak
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(matcha: matcha)
        var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)
        ttsWrapper = wrapper
        return true
    }

    /// Generate audio for `text` and play it. Queues if something is playing.
    /// If `interrupt` is true, kills current playback first.
    func speak(_ text: String, interrupt: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if interrupt {
            // All playback state lives on the main thread; marshal there.
            DispatchQueue.main.async { self.clearPlayback() }
        }
        // Inference on background queue.
        inferQueue.async { [weak self] in
            guard let self else { return }
            guard self.loadIfNeeded(), let wrapper = self.ttsWrapper else { return }
            let audio = wrapper.generate(text: text, sid: 0, speed: 1.0)
            let samples = audio.samples
            let sampleRate = Int(audio.sampleRate)
            guard !samples.isEmpty, sampleRate > 0 else { return }
            // Write WAV to temp file.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("piper-\(UUID().uuidString).wav")
            guard Self.writeWAV(samples: samples, sampleRate: sampleRate, to: url) else { return }
            DispatchQueue.main.async {
                self.enqueueFile(url, text: text)
            }
        }
    }

    /// Stop all playback + clear queue. Safe to call from any thread — the
    /// actual teardown is marshalled onto the main thread, the single owner of
    /// the playback state.
    func stop() {
        DispatchQueue.main.async { self.clearPlayback() }
    }

    /// MUST run on the main thread. Stops the current player and empties the
    /// queue. Sole mutator of currentPlayer/playbackQueue alongside
    /// enqueueFile/playFile/playNextInQueue/playerDidFinish.
    private func clearPlayback() {
        currentPlayer?.stop()
        currentPlayer = nil
        for entry in playbackQueue {
            try? FileManager.default.removeItem(at: entry.url)
        }
        playbackQueue.removeAll()
        Task { @MainActor in LyricTicker.shared.reset() }
    }

    /// True if anything is currently playing or queued. Reads the main-confined
    /// playback state safely from any caller thread.
    var isSpeaking: Bool {
        if Thread.isMainThread {
            return currentPlayer?.isPlaying == true || !playbackQueue.isEmpty
        }
        return DispatchQueue.main.sync {
            currentPlayer?.isPlaying == true || !playbackQueue.isEmpty
        }
    }

    // ---- internals (all run on the main thread) ----

    private func enqueueFile(_ url: URL, text: String) {
        if currentPlayer == nil || currentPlayer?.isPlaying == false {
            playFile(url, text: text)
        } else {
            playbackQueue.append((url: url, text: text))
        }
    }

    /// Pop the next queued clip and play it. No-op when the queue is empty.
    private func playNextInQueue() {
        guard !playbackQueue.isEmpty else { return }
        let next = playbackQueue.removeFirst()
        playFile(next.url, text: next.text)
    }

    private func playFile(_ url: URL, text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = playerDelegate
            p.prepareToPlay()
            // Drive the LyricTicker word-by-word using player duration as the
            // total time budget. simulateWords is @MainActor (runs a Timer
            // on the main run loop); we're on main here too but Swift's strict
            // concurrency requires the explicit hop.
            let duration = p.duration
            Task { @MainActor in
                LyricTicker.shared.simulateWords(in: text, duration: duration)
            }
            p.play()
            currentPlayer = p
        } catch {
            try? FileManager.default.removeItem(at: url)
            // Don't strand the rest of the queue on one bad clip — advance.
            currentPlayer = nil
            playNextInQueue()
        }
    }

    fileprivate func playerDidFinish(_ player: AVAudioPlayer) {
        // Delegate fires on the audio thread; hop to main where the playback
        // state lives, then clean up this WAV file and play the next, if any.
        DispatchQueue.main.async {
            if let path = player.url { try? FileManager.default.removeItem(at: path) }
            self.currentPlayer = nil
            self.playNextInQueue()
        }
    }

    /// Where the bundled espeak-ng-data lives. CI copies it from the sherpa-onnx
    /// tarball into whatsub-mobile/Resources/espeak-ng-data/, which becomes a
    /// resource directory inside the app bundle.
    private static var espeakDataPath: String? {
        Bundle.main.path(forResource: "espeak-ng-data", ofType: nil)
    }

    /// Where the TTS model files live. The 3 files (acoustic +
    /// vocoder + tokens) are bundled at the app bundle ROOT —
    /// project.yml's postBuildScripts copies them there directly
    /// after build, before codesign. Legacy fallback to the
    /// Documents downloader path is gone too — the old PiperModelDownloader
    /// runtime download path is dead since 2026-06-05.
    static var modelDir: URL? {
        let bundleRoot = Bundle.main.bundleURL
        // Detect via the acoustic model file. Was the Piper-style
        // "en_US-ljspeech-medium.onnx" file; swapped to Matcha's
        // "model-steps-3.onnx" on 2026-06-05.
        let acoustic = bundleRoot.appendingPathComponent("model-steps-3.onnx")
        return FileManager.default.fileExists(atPath: acoustic.path) ? bundleRoot : nil
    }

    /// Minimal float32 PCM WAV writer. Output: 32-bit float, mono, sampleRate.
    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) -> Bool {
        let bytesPerSample = 4
        let dataBytes = samples.count * bytesPerSample
        let chunkSize = 36 + dataBytes
        var data = Data()
        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(chunkSize).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)              // subchunk1 size
        data.append(UInt16(3).littleEndianData)               // audio format 3 = IEEE float
        data.append(UInt16(1).littleEndianData)               // num channels
        data.append(UInt32(sampleRate).littleEndianData)      // sample rate
        data.append(UInt32(sampleRate * bytesPerSample).littleEndianData)  // byte rate
        data.append(UInt16(bytesPerSample).littleEndianData)  // block align
        data.append(UInt16(32).littleEndianData)              // bits per sample
        // data chunk
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(dataBytes).littleEndianData)
        samples.withUnsafeBufferPointer { buf in
            data.append(contentsOf: UnsafeRawBufferPointer(buf))
        }
        return (try? data.write(to: url)) != nil
    }
}

private extension UInt32 {
    var littleEndianData: Data { withUnsafeBytes(of: self.littleEndian) { Data($0) } }
}

private extension UInt16 {
    var littleEndianData: Data { withUnsafeBytes(of: self.littleEndian) { Data($0) } }
}

/// AVAudioPlayer's delegate is a class requirement; nested classes can't be
/// NSObject delegates cleanly, so use this small helper that forwards back to
/// PiperTTS via a weak reference.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    weak var owner: PiperTTS?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        owner?.playerDidFinish(player)
    }
}
