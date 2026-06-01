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
    private var playbackQueue: [URL] = []
    private var currentPlayer: AVAudioPlayer?
    private let playerDelegate = PlayerDelegate()

    private init() {
        playerDelegate.owner = self
    }

    /// True iff model files are present on disk + espeak-ng-data bundle exists.
    var canSpeak: Bool {
        guard PiperModelDownloader.isLjspeechReady() else { return false }
        return Self.espeakDataPath != nil
    }

    /// Loads the model (idempotent). Heavy first-call latency expected.
    /// Returns true if the wrapper is now available, false otherwise.
    func loadIfNeeded() -> Bool {
        if ttsWrapper != nil { return true }
        guard canSpeak else { return false }
        if loadAttempted, ttsWrapper == nil { return false }
        loadAttempted = true

        let dir = PiperModelDownloader.ljspeechDir
        let onnx = dir.appendingPathComponent("en_US-ljspeech-medium.onnx").path
        let tokens = dir.appendingPathComponent("tokens.txt").path
        guard let espeak = Self.espeakDataPath else { return false }

        let vits = sherpaOnnxOfflineTtsVitsModelConfig(
            model: onnx,
            lexicon: "",
            tokens: tokens,
            dataDir: espeak
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(vits: vits)
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
            currentPlayer?.stop()
            currentPlayer = nil
            playbackQueue.removeAll()
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
                self.enqueueFile(url)
            }
        }
    }

    /// Stop all playback + clear queue.
    func stop() {
        currentPlayer?.stop()
        currentPlayer = nil
        for url in playbackQueue {
            try? FileManager.default.removeItem(at: url)
        }
        playbackQueue.removeAll()
    }

    /// True if anything is currently playing or queued.
    var isSpeaking: Bool {
        currentPlayer?.isPlaying == true || !playbackQueue.isEmpty
    }

    // ---- internals ----

    private func enqueueFile(_ url: URL) {
        if currentPlayer == nil || currentPlayer?.isPlaying == false {
            playFile(url)
        } else {
            playbackQueue.append(url)
        }
    }

    private func playFile(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = playerDelegate
            p.prepareToPlay()
            p.play()
            currentPlayer = p
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    fileprivate func playerDidFinish(_ player: AVAudioPlayer) {
        // Clean up this WAV file and play the next, if any.
        if let path = player.url { try? FileManager.default.removeItem(at: path) }
        currentPlayer = nil
        if let next = playbackQueue.first {
            playbackQueue.removeFirst()
            playFile(next)
        }
    }

    /// Where the bundled espeak-ng-data lives. CI copies it from the sherpa-onnx
    /// tarball into whatsub-mobile/Resources/espeak-ng-data/, which becomes a
    /// resource directory inside the app bundle.
    private static var espeakDataPath: String? {
        Bundle.main.path(forResource: "espeak-ng-data", ofType: nil)
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
            data.append(UnsafeRawBufferPointer(buf))
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
