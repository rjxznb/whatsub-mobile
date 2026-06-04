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
/// Recoverable errors from `VoiceActivityRecorder.start()`. The caller can
/// catch + surface a UI hint instead of crashing the whole app.
enum VoiceActivityError: Error {
    /// Mic input format came back with sampleRate ≤ 0 (typical right after
    /// a session category swap from .playback back to .playAndRecord — the
    /// hardware hasn't finished transitioning). Caller can retry after a
    /// short delay or fall back to typing.
    case audioHardwareNotReady(String)
}

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

    /// Safety cap for push-to-talk: even if the user keeps the finger on the
    /// orb (or accidentally puts the phone face-down while pressing), end the
    /// turn after this many seconds. 30 s is plenty of headroom for any
    /// realistic English-practice utterance.
    private let hardCapSec: Double = 30

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
    /// Segments SFSpeechRecognizer has finalized so far (it auto-finalizes
    /// after long silences, treating the next utterance as a fresh segment
    /// — each segment's `bestTranscription.formattedString` only covers
    /// its own audio, NOT a cumulative full transcript). We accumulate
    /// finalized segments here so a pause-then-resume doesn't lose the
    /// earlier half of what the user said. Caller sees the concatenation
    /// of finalizedSegments + lastPartialText.
    private var finalizedSegments: [String] = []
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
    /// Fires whenever the live ASR partial transcript changes (or a
    /// finalized segment lands). The transcript is the FULL accumulated
    /// utterance so far (finalized segments + current partial joined).
    /// Used by the view to render a real-time "what you're saying" line.
    var onPartialTranscript: ((String) -> Void)?

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

        // **CRASH GUARD** — observed in two production crash reports
        // (2026-06-03 054921 + 123537): when the audio session transitions
        // from .playback back to .playAndRecord, the inputNode's outputFormat
        // can return a temporarily-invalid format with sampleRate == 0. The
        // old code did `Int((1024.0 / 0.0) * 1000)` → +inf → Int conversion
        // trap → SIGTRAP on the main thread inside the gesture callback.
        // Reject cleanly so the caller can surface a "mic not ready" hint
        // rather than the whole app dying.
        guard format.sampleRate > 0,
              format.sampleRate.isFinite,
              format.channelCount > 0 else {
            throw VoiceActivityError.audioHardwareNotReady(
                "input format invalid (sampleRate=\(format.sampleRate), channels=\(format.channelCount))"
            )
        }

        let perBufferSec = 1024.0 / format.sampleRate
        let perBufferMs  = perBufferSec * 1000.0
        // Cap the conversion to keep Int() from ever seeing an out-of-range
        // value (belt + suspenders even after the format guard above).
        msPerBuffer = max(20, min(2000, Int(perBufferMs.rounded())))

        audioFile = try AVAudioFile(forWriting: url, settings: format.settings,
                                    commonFormat: format.commonFormat,
                                    interleaved: format.isInterleaved)

        // ASR (live, partial-stream). Force on-device when supported so we
        // don't ship audio to Apple's servers + so it works without VPN.
        // taskHint .dictation reduces the recognizer's eagerness to
        // auto-segment on natural pauses (it's the right hint for long-form
        // free speech; .search and .confirmation cut more aggressively).
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            // Tap callbacks land on a non-MainActor queue. Hop to MainActor
            // for the partial-stability update so the VAD state is single-
            // threaded with the audio-buffer processing.
            let text    = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                self?.handlePartialResult(text, isFinal: isFinal)
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
        finalizedSegments = []
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

    // MARK: - Push-to-talk loop (builds 237+)
    //
    // No more onset/offset auto-detection. The caller (QuickChatView) drives
    // start/stop explicitly via the orb's long-press gesture, so each buffer
    // we just (a) report level for the orb's voice reactivity and (b) honor
    // a hard cap so a stuck press can't record forever. The ASR partial
    // stream + endpointer-stability logic is also gone — the user releases
    // the orb to signal "I'm done", we don't need a heuristic for that.

    @MainActor
    func endRecording() {
        guard !finished else { return }
        endTurn(reason: .userRelease)
    }

    @MainActor
    private func processBuffer(powerDB power: Float) {
        guard !finished, let started = startedAt else { return }

        // Normalized level for the orb. -50 → 0, -10 → 1.
        let clamped = max(-50, min(-10, power))
        onLevelUpdate?((clamped + 50) / 40)

        // Hard cap as a safety net against a stuck press (e.g. user puts
        // phone face-down while still touching screen). 30 s matches the
        // previous hardCapSec.
        if Date().timeIntervalSince(started) > hardCapSec {
            endTurn(reason: .hardCap)
        }
    }

    // MARK: - Live transcript capture (no endpointing — caller drives end)

    @MainActor
    private func handlePartialResult(_ text: String, isFinal: Bool) {
        // Push-to-talk: end-of-turn is user-driven via the orb release.
        // We stash partial results AND watch for SFSpeechRecognizer's
        // own internal segment finalization (it auto-finalizes on long
        // silences within the same task — each `result` after that point
        // covers a NEW segment of audio, not the cumulative recording).
        // To prevent pause-then-resume from clobbering the earlier half
        // of what the user said, we drain finalized segments into
        // `finalizedSegments` and reset the partial buffer.
        guard !finished else { return }

        if isFinal {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { finalizedSegments.append(cleaned) }
            lastPartialText = ""
            lastPartialChangedAt = Date()
            onPartialTranscript?(accumulatedTranscript)
            return
        }

        if text != lastPartialText {
            // SF on-device occasionally auto-segments WITHOUT firing
            // isFinal — user reports of "chunk 1 disappears after a
            // mid-utterance pause". The handler above only drains
            // finalizedSegments when isFinal lands; without that signal
            // we'd just overwrite lastPartialText with chunk 2's text
            // and lose chunk 1. Detect the reset by checking if the
            // previous partial's tail still appears in the new partial
            // — normal partial-growth and SF refinements preserve the
            // suffix; a true segment reset doesn't.
            if Self.looksLikeRecognizerReset(prev: lastPartialText, new: text) {
                let cleaned = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    finalizedSegments.append(cleaned)
                }
            }
            lastPartialText = text
            lastPartialChangedAt = Date()
            onPartialTranscript?(accumulatedTranscript)
        }
    }

    /// True when the new partial text looks like a fresh SF utterance
    /// rather than an extension/refinement of the previous one. We only
    /// trip on substantive prev text (≥ 8 chars) so the very first
    /// partials of a session don't get treated as resets. The tail-12
    /// suffix is long enough to be specific (4+ alphanumeric chars
    /// after trim — Apple's recognizer doesn't lose 12 chars of context
    /// across a refine) and short enough to tolerate minor punctuation
    /// or capitalisation tweaks at the end. Conservative bias: false
    /// negatives are visible to the user (chunk doesn't reset → no
    /// harm); false positives mean the same text appears twice in the
    /// final transcript (LLM still understands, slightly less clean).
    private static func looksLikeRecognizerReset(prev: String, new: String) -> Bool {
        guard prev.count >= 8 else { return false }
        let tail = String(prev.suffix(12))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard tail.count >= 4 else { return false }
        return !new.lowercased().contains(tail)
    }

    /// Caller-visible transcript = all finalized segments joined + the
    /// running partial. We never lose the early half of the utterance
    /// even if the recognizer auto-segmented on a mid-sentence pause.
    private var accumulatedTranscript: String {
        var parts = finalizedSegments
        let trimmedPartial = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPartial.isEmpty { parts.append(trimmedPartial) }
        return parts.joined(separator: " ")
    }

    // MARK: - Termination

    private enum EndReason { case userRelease, hardCap }

    @MainActor
    private func endTurn(reason: EndReason) {
        guard !finished else { return }
        finished = true
        let transcript = accumulatedTranscript
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

        // (2026-06-03, revised) Restore playback-friendly MODE only — DO NOT
        // change the category. Earlier code swapped category from
        // .playAndRecord → .playback after each recording to lift the TTS
        // volume, but the next press needed to swap back to .playAndRecord
        // and the hardware took a few ms to settle; meanwhile
        // inputNode.outputFormat returned sampleRate=0 and start() trapped
        // on Int(1024.0 / 0). Two production crashes confirmed it.
        //
        // Staying in .playAndRecord across both record and playback means:
        //   • input hardware stays initialised → no sampleRate=0 race
        //   • mode swap (measurement ↔ spokenAudio) is cheap (no hardware
        //     reset), still restores playback-loud volume
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
        } catch {
            // Best-effort. If this fails the user can still hear the AI,
            // just at the muted measurement-mode level.
        }
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
