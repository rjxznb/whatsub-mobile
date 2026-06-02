import AVFoundation
import Speech

/// Voice activity detection driven by AVAudioEngine input tap. Replaces the
/// previous AVAudioRecorder polling implementation (builds ≤ 232) for two
/// reasons:
///
/// 1. **Adaptive (relative-dB) offset** — the old absolute -34 dBFS threshold
///    couldn't tell user's voice from typical room ambient (fan/AC/traffic
///    often sit at -35 to -28 dBFS), so silentSinceMs never accumulated and
///    the orb stuck in 'listening' until the 12 s hard cap fired. The tap
///    callback gives us the raw audio frames, so we track peak dBFS since
///    onset and use `max(peak - 15 dB, -38 dB floor)` as the offset gate.
///    Quiet speakers in quiet rooms get a generous threshold; loud speakers
///    in noisy rooms get a tight one — both relative to THEIR voice.
///
/// 2. **Live ASR partial-transcript stability ("Siri-style")** — even
///    relative dB can miss "user mumbled to a stop with audible sigh / room
///    noise that exceeded the floor". The same audio frames are also piped
///    into a streaming SFSpeechRecognizer with shouldReportPartialResults.
///    When the partial transcript hasn't changed for 1.2 s AND we already
///    have at least one word, we end the turn — Apple's ML endpointer is
///    doing exactly this for Siri.
///
/// Either signal can end the turn (OR semantics) — we report whichever
/// fires first, so the user never has to wait on the slower one.
///
/// Returns the recognized transcript directly via `onSpeechEnded` — the
/// post-recording SFSpeechRecognizer call the view model used to do is no
/// longer needed.
final class VoiceActivityRecorder {

    // MARK: - Tunable thresholds (A + B parameters)

    /// Absolute onset gate. Power above this for `onsetHoldMs` ⇒ onset.
    private let speechOnsetDB: Float = -28

    /// Relative offset is `max(peak - relativeOffsetDB, absoluteOffsetFloor)`.
    /// 15 dB below the user's peak is a wide margin for "definitely quieter";
    /// the floor prevents the threshold from sinking below room ambient when
    /// the user has been very loud.
    private let relativeOffsetDB: Float = 15
    private let absoluteOffsetFloor: Float = -38

    /// Hold durations.
    private let onsetHoldMs: Int = 200
    private let offsetHoldMs: Int = 1000

    /// Time after onset by which we force-end regardless of VAD/ASR
    /// (belt-and-suspenders for pathologically loud sustained noise).
    private let maxAfterOnsetSec: Double = 12

    /// No-speech timeout BEFORE onset.
    private let noSpeechTimeoutSec: Double = 15

    /// "Stable partial" window — if SFSpeechRecognizer's partial text hasn't
    /// changed for this long AND we have at least one word, end the turn.
    /// 1.2 s matches what Siri/Google Assistant use empirically.
    private let partialStableSec: Double = 1.2

    // MARK: - Runtime state

    private let engine = AVAudioEngine()
    private var fileURL: URL?
    private var audioFile: AVAudioFile?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var startedAt: Date?
    private var onsetAt: Date?
    private var loudSinceMs: Int = 0
    private var silentSinceMs: Int = 0
    private var peakSinceOnset: Float = -100
    private var lastPartialText: String = ""
    private var lastPartialChangedAt: Date?
    private var finished: Bool = false

    /// Approximate ms per tap buffer at 16 kHz mono with 1024 frames
    /// (≈ 64 ms). Used to advance the loudSinceMs / silentSinceMs counters.
    private var msPerBuffer: Int = 64

    // MARK: - Callbacks

    var onSpeechDetected: (() -> Void)?
    /// Called with the live ASR transcript (may be empty if user was just
    /// silent / VAD timed out the post-onset cap with no words). The optional
    /// URL is the backup .caf file if the caller wants to re-recognize.
    var onSpeechEnded: ((_ transcript: String, _ backupAudioURL: URL?) -> Void)?
    var onNoSpeechTimeout: (() -> Void)?
    /// Fires every audio buffer (~60 ms) with a normalized 0..1 amplitude.
    /// Drives real-time orb reactivity in the view.
    var onLevelUpdate: ((Float) -> Void)?

    // MARK: - Lifecycle

    @MainActor
    func start() throws {
        // Audio session — same shape as the AVAudioRecorder path. Measurement
        // mode disables built-in processing so the dBFS reading is honest.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])

        // Backup file (PCM .caf — no codec drama, can be re-recognized later
        // if a caller decides the live transcript needs verification).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-vad-\(UUID().uuidString).caf")
        fileURL = url

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        msPerBuffer = max(20, Int((Double(1024) / format.sampleRate) * 1000))
        audioFile = try AVAudioFile(forWriting: url, settings: format.settings,
                                    commonFormat: format.commonFormat,
                                    interleaved: format.isInterleaved)

        // ASR (live, partial-stream). Force on-device when supported so we
        // don't ship audio to Apple's servers + so it works without VPN.
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            // Tap callbacks land on a non-MainActor queue. Hop to MainActor
            // for the partial-stability update so the VAD state is single-
            // threaded with the audio-buffer processing.
            let text = result?.bestTranscription.formattedString ?? ""
            Task { @MainActor in
                self?.handlePartialResult(text)
            }
        }

        // Install the audio tap. This callback fires on a real-time thread,
        // so we keep the work in here minimal: write the buffer + feed it to
        // the ASR + compute RMS + hop to MainActor for the FSM step.
        input.removeTap(onBus: 0)   // belt-and-suspenders if a previous start failed mid-init
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.audioFile?.write(from: buffer)
            self.recognitionRequest?.append(buffer)
            let power = Self.dB(of: buffer)
            Task { @MainActor in
                self.processBuffer(powerDB: power)
            }
        }

        engine.prepare()
        try engine.start()

        startedAt = Date()
        onsetAt = nil
        loudSinceMs = 0
        silentSinceMs = 0
        peakSinceOnset = -100
        lastPartialText = ""
        lastPartialChangedAt = nil
        finished = false
    }

    @MainActor
    func cancel() {
        teardown()
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }

    // MARK: - VAD FSM (Method A: relative-dB)

    @MainActor
    private func processBuffer(powerDB power: Float) {
        guard !finished, let started = startedAt else { return }

        // Normalized level for the orb. -50 → 0, -10 → 1.
        let clamped = max(-50, min(-10, power))
        onLevelUpdate?((clamped + 50) / 40)

        let now = Date()
        let elapsedSec = now.timeIntervalSince(started)

        if onsetAt == nil {
            // Looking for onset.
            if elapsedSec > noSpeechTimeoutSec {
                teardown()
                if let url = fileURL { try? FileManager.default.removeItem(at: url) }
                fileURL = nil
                onNoSpeechTimeout?()
                return
            }
            if power > speechOnsetDB {
                loudSinceMs += msPerBuffer
                if loudSinceMs >= onsetHoldMs {
                    onsetAt = now
                    peakSinceOnset = power
                    onSpeechDetected?()
                }
            } else {
                loudSinceMs = 0
            }
            return
        }

        // After onset — hard cap.
        if let onsetAt, now.timeIntervalSince(onsetAt) > maxAfterOnsetSec {
            endTurn(reason: .hardCap)
            return
        }

        // Track peak voltage so the relative threshold can adapt.
        if power > peakSinceOnset { peakSinceOnset = power }
        let offsetThreshold = max(peakSinceOnset - relativeOffsetDB, absoluteOffsetFloor)

        if power < offsetThreshold {
            silentSinceMs += msPerBuffer
            if silentSinceMs >= offsetHoldMs {
                endTurn(reason: .silenceVAD)
                return
            }
        } else {
            silentSinceMs = 0
        }
    }

    // MARK: - Method B: ASR partial stability

    @MainActor
    private func handlePartialResult(_ text: String) {
        guard !finished, onsetAt != nil else {
            // Pre-onset partials are noise; ignore.
            lastPartialText = text
            return
        }
        if text != lastPartialText {
            lastPartialText = text
            lastPartialChangedAt = Date()
            return
        }
        // Same text as last partial — check if it's been stable long enough.
        guard !text.isEmpty, let changed = lastPartialChangedAt else { return }
        if Date().timeIntervalSince(changed) >= partialStableSec {
            endTurn(reason: .asrStable)
        }
    }

    // MARK: - Termination

    private enum EndReason { case silenceVAD, asrStable, hardCap }

    @MainActor
    private func endTurn(reason: EndReason) {
        guard !finished else { return }
        finished = true
        let transcript = lastPartialText
        let url = fileURL
        teardown()
        onSpeechEnded?(transcript, url)
    }

    @MainActor
    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil
    }

    // MARK: - Helpers

    /// RMS-based dBFS estimate of a float PCM buffer. Single-channel only —
    /// caller's format is mono. ~50 µs per call at 1024 frames; cheap enough
    /// for every tap callback on a real-time thread.
    private static func dB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -100 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return -100 }
        var sumSq: Float = 0
        for i in 0..<n {
            let s = channelData[i]
            sumSq += s * s
        }
        let rms = (sumSq / Float(n)).squareRoot()
        if rms < 1e-7 { return -100 }
        return 20 * log10f(rms)
    }
}
