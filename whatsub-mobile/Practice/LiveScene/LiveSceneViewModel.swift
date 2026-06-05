import Foundation
import UIKit

/// FSM driving the 实景口语练习 sheet. Phases are linear (no jumps) and the
/// user can only ABANDON (close the sheet) or RESTART (回到 picker) — not
/// jump back to a previous phase, since each phase consumed an LLM call
/// and re-entering would burn quota.
///
///   picker → classifying → prompting → ready → recording → grading → review
///                                                                      ↓
///                                                                   再来一次 → picker
///
/// 2026-06-05.
@MainActor
final class LiveSceneViewModel: ObservableObject {

    enum Phase: Equatable {
        /// Initial — show 「拍照」/「相册」 picker buttons.
        case picker
        /// Vision running. Briefly shown — usually < 100ms.
        case classifying
        /// LLM prompt-derivation in flight.
        case prompting
        /// Prompt ready, user reads it, taps and holds to record.
        case ready(scene: SceneContext, prompt: SpeakingPrompt)
        /// User is currently pressing the orb / button.
        case recording(scene: SceneContext, prompt: SpeakingPrompt, livePartial: String)
        /// LLM grading in flight.
        case grading(scene: SceneContext, prompt: SpeakingPrompt, transcript: String)
        /// Final result + 再来一次 / 完成 buttons.
        case review(scene: SceneContext, prompt: SpeakingPrompt, transcript: String, grade: SceneGrade)
        /// Recoverable error — UI shows banner + 重试 / 取消.
        case error(String)
    }

    @Published private(set) var phase: Phase = .picker

    /// `onLevelUpdate` callback drives the orb's reactivity here; the
    /// view binds to this to animate. 0..1 normalized.
    @Published private(set) var audioLevel: Float = 0

    private let promptClient: LiveScenePromptClient
    private let grader: LiveSceneGrader
    private var recorder: VoiceActivityRecorder?

    init(
        promptClient: LiveScenePromptClient = .live(),
        grader: LiveSceneGrader = .live()
    ) {
        self.promptClient = promptClient
        self.grader = grader
    }

    // MARK: - phase transitions

    /// Picker delivered an image. Run Vision → LLM prompt-derivation.
    func didPickImage(_ image: UIImage) async {
        phase = .classifying
        let classifyResult = await SceneClassifier.classify(image)
        switch classifyResult {
        case .failure(let msg):
            phase = .error(msg)
            return
        case .success(let scene):
            phase = .prompting
            let promptResult = await promptClient.derive(scene: scene)
            switch promptResult {
            case .failure(let msg):
                phase = .error(msg)
            case .success(let prompt):
                phase = .ready(scene: scene, prompt: prompt)
            }
        }
    }

    /// User pressed the record button. Spin up the recorder + hook
    /// callbacks. Caller (the view) shouldn't await — the press gesture
    /// returns immediately; we drive UI via `phase` + `audioLevel`.
    func startRecording() {
        guard case let .ready(scene, prompt) = phase else { return }
        let rec = VoiceActivityRecorder()
        rec.onLevelUpdate = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        rec.onPartialTranscript = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                if case let .recording(s, p, _) = self.phase {
                    self.phase = .recording(scene: s, prompt: p, livePartial: text)
                }
            }
        }
        rec.onSpeechEnded = { [weak self] transcript, _ in
            Task { @MainActor in self?.didFinishRecording(transcript: transcript) }
        }
        do {
            try rec.start()
            recorder = rec
            phase = .recording(scene: scene, prompt: prompt, livePartial: "")
        } catch let e as VoiceActivityError {
            // Mic not ready — usually transient. Tell the user instead of
            // silently failing; they can tap again.
            switch e {
            case .audioHardwareNotReady:
                phase = .error("麦克风未就绪,稍等一下再按住")
            }
        } catch {
            phase = .error("录音启动失败:\(error.localizedDescription)")
        }
    }

    /// User released the record button. Tell the recorder to finalize —
    /// it'll fire `onSpeechEnded` with the accumulated transcript, which
    /// routes through `didFinishRecording` below.
    func endRecording() {
        guard case .recording = phase else { return }
        recorder?.endRecording()
    }

    private func didFinishRecording(transcript: String) {
        recorder = nil
        audioLevel = 0
        // Pull the scene/prompt out of the recording state so we can
        // switch into grading with the same context.
        guard case let .recording(scene, prompt, _) = phase else { return }
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty transcript = user didn't actually say anything (or ASR
        // failed entirely). Skip the grading LLM call (waste of token)
        // and surface a re-record path.
        if cleaned.isEmpty {
            phase = .error("没听清你说什么,再按住按钮说一遍")
            return
        }
        phase = .grading(scene: scene, prompt: prompt, transcript: cleaned)
        Task { await runGrader(scene: scene, prompt: prompt, transcript: cleaned) }
    }

    private func runGrader(scene: SceneContext, prompt: SpeakingPrompt, transcript: String) async {
        let result = await grader.grade(prompt: prompt, userTranscript: transcript)
        switch result {
        case .failure(let msg):
            phase = .error(msg)
        case .success(let grade):
            phase = .review(scene: scene, prompt: prompt, transcript: transcript, grade: grade)
        }
    }

    /// Review's 「再来一次」 — drop the result, return to the picker so
    /// the user can pick a new photo (or the same one with a fresh Vision
    /// pass — Vision results are cheap so we don't cache).
    func restart() {
        recorder?.cancel()
        recorder = nil
        audioLevel = 0
        phase = .picker
    }

    /// Error state → go back to picker (lets the user try a different
    /// photo if Vision failed, or retry if it was a transient LLM error).
    func dismissError() {
        recorder?.cancel()
        recorder = nil
        audioLevel = 0
        phase = .picker
    }

    /// Sheet is being torn down — make sure the recorder isn't left
    /// holding the audio session open.
    func tearDown() {
        recorder?.cancel()
        recorder = nil
    }
}
