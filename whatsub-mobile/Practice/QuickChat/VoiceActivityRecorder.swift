import AVFoundation

/// Continuous-recording VAD (voice activity detection). Starts AVAudioRecorder,
/// polls `averagePower` every 100ms, emits state callbacks:
///
/// - onSpeechDetected: fires once when sustained loud audio is heard.
/// - onSpeechEnded: fires once when silence after onset persists, with the
///   recorded audio file URL. After this, caller transcribes and decides next step.
/// - onNoSpeechTimeout: fires if no onset is detected within timeout — caller
///   may end the session.
///
/// Thresholds tuned for typical phone-held-to-face usage with .playAndRecord +
/// .measurement mode + .defaultToSpeaker. They may need adjustment for AirPods.
final class VoiceActivityRecorder {

    // Tunable thresholds.
    private let speechOnsetDB: Float = -30        // power above this for onsetHoldMs = onset
    private let speechOffsetDB: Float = -40       // power below this for offsetHoldMs after onset = offset
    private let onsetHoldMs: Int = 200
    private let offsetHoldMs: Int = 1500
    private let pollIntervalMs: Int = 100
    private let noSpeechTimeoutSec: Double = 15
    private let hardCapSec: Double = 30           // even if speaking continuously, cap recording

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var pollTask: Task<Void, Never>?
    private var startedAt: Date?
    private var onsetAt: Date?
    private var loudSinceMs: Int = 0
    private var silentSinceMs: Int = 0

    var onSpeechDetected: (() -> Void)?
    var onSpeechEnded: ((URL) -> Void)?
    var onNoSpeechTimeout: (() -> Void)?

    /// Start the recorder + polling. Throws if AVAudioRecorder init fails.
    /// Returns immediately (polling runs on a Task).
    @MainActor
    func start() throws {
        // Audio session — switch to .playAndRecord with measurement mode (matches ShadowSheet pattern).
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("qc-vad-\(UUID().uuidString).m4a")
        url = fileURL
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let r = try AVAudioRecorder(url: fileURL, settings: settings)
        r.isMeteringEnabled = true
        r.record()
        recorder = r
        startedAt = Date()
        onsetAt = nil
        loudSinceMs = 0
        silentSinceMs = 0

        startPolling()
    }

    /// Manually stop early (e.g. user closed sheet). No callback fires.
    @MainActor
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        recorder?.stop()
        recorder = nil
        if let url, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        url = nil
    }

    // ---- internals ----

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.pollIntervalMs ?? 100) * 1_000_000)
                if Task.isCancelled { return }
                await self?.poll()
            }
        }
    }

    @MainActor
    private func poll() {
        guard let r = recorder, r.isRecording, let started = startedAt else { return }
        r.updateMeters()
        let power = r.averagePower(forChannel: 0)
        let now = Date()
        let elapsedSec = now.timeIntervalSince(started)

        // Hard cap.
        if elapsedSec > hardCapSec {
            finishWithRecording()
            return
        }

        // No-speech timeout — only counts before onset.
        if onsetAt == nil, elapsedSec > noSpeechTimeoutSec {
            cancelWithoutCallback()
            onNoSpeechTimeout?()
            return
        }

        if onsetAt == nil {
            // Looking for onset.
            if power > speechOnsetDB {
                loudSinceMs += pollIntervalMs
                if loudSinceMs >= onsetHoldMs {
                    onsetAt = now
                    onSpeechDetected?()
                }
            } else {
                loudSinceMs = 0
            }
        } else {
            // Looking for offset.
            if power < speechOffsetDB {
                silentSinceMs += pollIntervalMs
                if silentSinceMs >= offsetHoldMs {
                    finishWithRecording()
                    return
                }
            } else {
                silentSinceMs = 0
            }
        }
    }

    @MainActor
    private func finishWithRecording() {
        pollTask?.cancel()
        pollTask = nil
        recorder?.stop()
        let savedURL = url
        recorder = nil
        url = nil
        if let savedURL { onSpeechEnded?(savedURL) }
    }

    @MainActor
    private func cancelWithoutCallback() {
        pollTask?.cancel()
        pollTask = nil
        recorder?.stop()
        recorder = nil
        if let url, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        url = nil
    }
}
