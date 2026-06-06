import SwiftUI
import PhotosUI
import AVFoundation

/// 实景口语练习 surface. Phase-driven content tree: picker → Vision →
/// LLM prompt → press-and-hold record → LLM grade → review.
///
/// Hosted INLINE inside `CameraTabView` (the 实景口语 tab) rather than
/// presented as a sheet (build 2026-06-05+). The parent owns the nav
/// chrome (title + top-right 拍照翻译 button); this view just renders
/// the phase-driven body.
///
/// Reuses `PhotoCameraPicker` / `PhotosPicker` from the photo flow + the
/// `VoiceActivityRecorder` + `VoiceOrbView` from QuickChat. The orb is
/// the same Liquid-Glass shader QuickChat uses — feels native + makes
/// the recording surface feel like the QuickChat session, just gated by
/// push-to-talk instead of auto-VAD.
///
/// 2026-06-05.
struct LiveSceneView: View {
    @StateObject private var vm = LiveSceneViewModel()

    // Picker presentation state — local to the view, kept out of vm
    // because they're pure UI surfaces, not business state.
    @State private var showCamera = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var cameraImage: UIImage?

    /// Progressive-scaffolding 提示 cycle (build 2026-06-05+):
    ///   .none           → only the English prompt + vocab chips visible
    ///   .zh             → also reveal the Chinese hint (promptZh)
    ///   .zhAndSample    → also reveal the English sample answer
    /// Cycles back to .none on the 4th tap so the user can hide hints
    /// and try fresh. Reset to .none whenever a new prompt loads (see
    /// .onChange below) — past hints shouldn't leak across exercises.
    @State private var hintLevel: HintLevel = .none

    /// Single sharp impact on each orb tap. Same `UIImpactFeedbackGenerator`
    /// pattern QuickChat uses. Bumped intensity 0.85 → 1.0 to match
    /// QuickChat — user reported the orb tap was "no haptic feedback"
    /// on the 0.85 setting (2026-06-06). UIImpactFeedbackGenerator
    /// needs `prepare()` called before the first actual impact for
    /// low-latency hardware activation; we do that in `.onAppear`.
    private let pressHaptic = UIImpactFeedbackGenerator(style: .rigid)
    enum HintLevel: Int, Comparable {
        case none = 0, zh = 1, zhAndSample = 2
        static func < (lhs: HintLevel, rhs: HintLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
        var next: HintLevel {
            switch self {
            case .none: return .zh
            case .zh: return .zhAndSample
            case .zhAndSample: return .none
            }
        }
    }

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // .fullScreenCover (NOT .sheet) for the camera picker —
        // UIImagePickerController is designed to take the whole screen
        // (shutter + flip + flash all positioned assuming full-screen
        // bounds). In a SwiftUI .sheet (iOS 16+ form-sheet style by
        // default) the shutter button gets clipped or hidden under
        // the sheet chrome. User reported "拍照按钮消失了" on the
        // build 1db6f6c camera picker.
        .fullScreenCover(isPresented: $showCamera) {
            PhotoCameraPicker(image: $cameraImage)
                .ignoresSafeArea()
        }
        .onChange(of: cameraImage) { newImage in
            if let img = newImage {
                cameraImage = nil
                Task { await vm.didPickImage(img) }
            }
        }
        .onChange(of: photoPickerItem) { newItem in
            guard let item = newItem else { return }
            photoPickerItem = nil
            Task {
                if let img = await PhotoLibraryPicker.resolve(item) {
                    await vm.didPickImage(img)
                }
            }
        }
        // Reset the 提示 reveal level whenever the user lands on a fresh
        // prompt (new pick → new derivation). Past hints shouldn't carry
        // across exercises and prejudice the next attempt.
        .onChange(of: phaseKey(vm.phase)) { _ in
            hintLevel = .none
        }
        // Don't tear down on .onDisappear — tab switches fire it too, and
        // we want the prompt + captured image to persist when the user
        // comes back to this tab. The recorder cleans up its own audio
        // session on each endRecording() call, so a tab switch mid-prompt
        // leaks nothing. (If the user is HOLDING the orb during a tab
        // switch — rare — the recorder's 30s hardCap or the next press's
        // teardown cleans up; not worth special-casing.)
        //
        // **Pre-warm the AVAudioSession on view appear** — every prior
        // orb attempt (#7-#9) showed the UIControl/UIView gesture
        // getting killed within ~50-150ms of recorder.start(), which
        // is when the audio session activates `.playAndRecord` mode.
        // Activating the session here, BEFORE the user presses, means
        // recorder.start()'s session calls become no-ops (already in
        // the right state), and there's no mid-press audio reroute to
        // disrupt the touch.
        .onAppear {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord,
                                     mode: .measurement,
                                     options: [.defaultToSpeaker, .allowBluetooth])
            try? session.setActive(true, options: [])
            // Warm up the Taptic Engine so the very first orb tap fires
            // with low latency. UIImpactFeedbackGenerator goes "cold"
            // after a few seconds of inactivity; we re-prepare after
            // each tap too (see orbBlock).
            pressHaptic.prepare()
        }
    }

    /// Reduce Phase to a small key string for onChange — Phase isn't
    /// Hashable (associated values include UIImage / SceneContext which
    /// aren't naturally so), and we only care about "did we transition
    /// to a new prompt" for the hint-reset.
    private func phaseKey(_ p: LiveSceneViewModel.Phase) -> String {
        switch p {
        case .picker: return "picker"
        case .classifying: return "classifying"
        case .prompting: return "prompting"
        case .ready: return "ready"
        case .recording: return "recording"
        case .grading: return "grading"
        case .review: return "review"
        case .error: return "error"
        }
    }

    // MARK: - phase router

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .picker:
            pickerView
        case .classifying:
            loadingView(text: "正在识别画面…")
        case .prompting:
            loadingView(text: "正在为你出题…")
        case let .ready(_, prompt):
            promptView(prompt: prompt, isRecording: false, livePartial: "")
        case let .recording(_, prompt, livePartial):
            promptView(prompt: prompt, isRecording: true, livePartial: livePartial)
        case .grading:
            loadingView(text: "正在评分…")
        case let .review(_, prompt, transcript, grade):
            reviewView(prompt: prompt, transcript: transcript, grade: grade)
        case let .error(msg):
            errorView(msg)
        }
    }

    // MARK: - picker

    private var pickerView: some View {
        VStack(spacing: 24) {
            Spacer()
            // Center icon: the multi-color mountains asset (was eye.circle
            // SF Symbol). Same asset that lives in the asset catalog as
            // LiveSceneCardIcon — brand palette mountains + yellow sun.
            // Bigger here (88pt) than in the old card row (36pt) — this
            // is the empty-state hero.
            Image("LiveSceneCardIcon")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
            VStack(spacing: 8) {
                Text("拍一张你眼前的画面")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                Text("AI 会根据画面给你出一个英语口语题,练完会给评分 + 标准答案")
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            VStack(spacing: 12) {
                if deviceHasCamera {
                    Button {
                        showCamera = true
                    } label: {
                        Label("拍照", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.whatsubAccent, in: Capsule())
                            .foregroundStyle(.black)
                            .font(.body.weight(.semibold))
                    }
                }
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Label("从相册选", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.whatsubBgElev, in: Capsule())
                        .foregroundStyle(.whatsubInk)
                        .font(.body.weight(.semibold))
                }
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: - loading

    private func loadingView(text: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().tint(.whatsubAccent).scaleEffect(1.2)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
            Spacer()
        }
    }

    // MARK: - prompt (ready + recording share the same shape)

    @ViewBuilder
    private func promptView(prompt: SpeakingPrompt, isRecording: Bool, livePartial: String) -> some View {
        // ScrollView + orb are SIBLINGS in a VStack — NOT nested via
        // .safeAreaInset(edge: .bottom). That nesting (used in builds
        // d7e501a → 78fd1a9) had ScrollView's pan recognizer competing
        // with the orb's DragGesture: a long press without movement is
        // exactly what ScrollView watches for to "claim" a future
        // scroll, and once it claims, our DragGesture gets CANCELLED
        // without onEnded firing — that's the "release didn't end
        // recording" bug. QuickChat doesn't hit this because its orb
        // sits in a plain VStack with no ScrollView ancestor.
        //
        // Sibling layout: ScrollView takes the upper remaining space
        // (flex grow), orb is fixed-height at the bottom. The orb has
        // no scroll-recognizer ancestor, so its DragGesture owns the
        // touch lifecycle outright.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Top row: difficulty stars on the left, photo thumbnail
                    // on the right so the user keeps "what they were asked
                    // about" visible alongside the prompt text.
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            difficultyRow(prompt.difficulty)
                            Text(prompt.promptEn)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.whatsubInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if let img = vm.capturedImage {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 76, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    // 提示 button + progressive reveal cards. Hidden by
                    // default; user opts in when stuck.
                    hintBlock(prompt: prompt)

                    if !prompt.targetVocab.isEmpty {
                        vocabChips(prompt.targetVocab)
                    }
                    if isRecording && !livePartial.isEmpty {
                        Text(livePartial)
                            .font(.subheadline)
                            .foregroundStyle(.whatsubInk)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(20)
            }
            orbBlock(isRecording: isRecording)
                .padding(.bottom, 24)
        }
    }

    // MARK: - hint block (progressive reveal)

    @ViewBuilder
    private func hintBlock(prompt: SpeakingPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                hintLevel = hintLevel.next
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.caption.weight(.semibold))
                    Text(hintButtonLabel)
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.whatsubBgElev))
                .foregroundStyle(.whatsubAccent)
            }
            .buttonStyle(.plain)

            if hintLevel >= .zh, !prompt.promptZh.isEmpty {
                hintCard(title: "中文提示", body: prompt.promptZh)
            }
            if hintLevel >= .zhAndSample, !prompt.sampleAnswer.isEmpty {
                hintCard(title: "参考答案 (英文)", body: prompt.sampleAnswer)
            }
        }
    }

    private var hintButtonLabel: String {
        switch hintLevel {
        case .none: return "提示"
        case .zh: return "更多提示 (示范答案)"
        case .zhAndSample: return "隐藏提示"
        }
    }

    private func hintCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
            Text(body)
                .font(.footnote)
                .foregroundStyle(.whatsubInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - difficulty + vocab chips

    private func difficultyRow(_ difficulty: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(1...3, id: \.self) { i in
                Image(systemName: i <= difficulty ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(.whatsubAccent)
            }
            Text(["A2 · 简单", "B1 · 中等", "B2 · 进阶"][max(0, min(2, difficulty - 1))])
                .font(.caption2)
                .foregroundStyle(.whatsubInkMuted)
        }
    }

    private func vocabChips(_ vocab: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("建议用上")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vocab, id: \.self) { v in
                        Text(v)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.whatsubBgElev))
                            .foregroundStyle(.whatsubInk)
                    }
                }
            }
        }
    }

    // MARK: - orb (tap-to-toggle)

    // (9 prior attempts at making push-to-talk work — DragGesture
    // inline / closure-vm-phase / computed-property+@State / no-
    // ScrollView / UILongPressGestureRecognizer / Button+ButtonStyle /
    // raw touchesBegan/Ended/Cancelled / UIControl target-action /
    // UIControl manual tracking — all hit "release event silently
    // swallowed" in some layer. User asked for tap-to-toggle 2026-06-05
    // and it works first try; the entire push-to-talk apparatus
    // including PushToTalkOverlay.swift is now dead but kept for
    // forensic value.)

    /// Tap-to-toggle orb. After 9 failed attempts at making the
    /// push-to-talk touch lifecycle reliable in this view tree (every
    /// SwiftUI gesture and every UIKit recogniser/touch override got
    /// killed by something between the audio session activation and
    /// the SwiftUI/UIControl re-layout), switched to a SIMPLE
    /// discrete-tap UX: tap once to start, tap again to end.
    ///
    /// Why this works where 9 push-to-talk variants failed: SwiftUI
    /// Button's action callback handles ONE discrete tap event end
    /// to end — no separate press/release lifecycle for the OS or
    /// gesture coordinator to silently de-sync. Recording itself
    /// then runs uninterrupted between the two taps; the audio
    /// session pre-warm on .onAppear means there's no mid-session
    /// reroute either.
    @ViewBuilder
    private func orbBlock(isRecording: Bool) -> some View {
        VStack(spacing: 4) {
            Button {
                pressHaptic.impactOccurred(intensity: 1.0)
                pressHaptic.prepare()   // warm up for the NEXT tap
                if isRecording {
                    vm.endRecording()
                } else if case .ready = vm.phase {
                    vm.startRecording()
                }
            } label: {
                VoiceOrbView(
                    state: isRecording ? .recording : .idle,
                    audioLevel: vm.audioLevel,
                    isPressed: isRecording,
                    baseSize: 110
                )
            }
            .buttonStyle(.plain)
            Text(isRecording ? "点击结束" : "点击说英语")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
        }
    }

    // MARK: - review

    private func reviewView(prompt: SpeakingPrompt, transcript: String, grade: SceneGrade) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                scoreCard(grade.score)
                section("你的回答") {
                    Text(transcript)
                        .font(.subheadline)
                        .foregroundStyle(.whatsubInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !grade.feedback.isEmpty {
                    section("点评") {
                        Text(grade.feedback)
                            .font(.subheadline)
                            .foregroundStyle(.whatsubInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Reference answer now sourced from prompt.sampleAnswer
                // (pre-computed at derivation time) — see SceneGrade
                // comment for why we dropped grader.modelAnswer.
                if !prompt.sampleAnswer.isEmpty {
                    section("参考答案") {
                        Text(prompt.sampleAnswer)
                            .font(.subheadline)
                            .foregroundStyle(.whatsubInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !grade.vocabHits.isEmpty {
                    section("目标短语") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(grade.vocabHits) { hit in
                                vocabHitRow(hit)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    vm.restart()
                } label: {
                    Text("再来一张")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.whatsubBgElev, in: Capsule())
                        .foregroundStyle(.whatsubInk)
                        .font(.body.weight(.semibold))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    private func scoreCard(_ score: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= score ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(i <= score ? .whatsubAccent : .whatsubInkFaint)
            }
            Spacer()
            Text("\(score) / 5")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
        }
        .padding(16)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
            content()
        }
    }

    private func vocabHitRow(_ hit: VocabHit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hit.correct ? "checkmark.circle.fill" :
                              hit.attempted ? "xmark.circle.fill" : "circle")
                .foregroundStyle(hit.correct ? .green :
                                 hit.attempted ? .red : .whatsubInkFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.phrase)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                if !hit.note.isEmpty {
                    Text(hit.note)
                        .font(.caption)
                        .foregroundStyle(.whatsubInkMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - error

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.whatsubInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                vm.dismissError()
            } label: {
                Text("重新选图片")
                    .padding(.horizontal, 32).padding(.vertical, 12)
                    .background(Color.whatsubAccent, in: Capsule())
                    .foregroundStyle(.black)
                    .font(.body.weight(.semibold))
            }
            Spacer()
        }
    }
}

// PressDetectingButtonStyle removed 2026-06-05 — Button's .isPressed
// transitions had the same silent-cancellation symptom as raw gestures.
// Replaced by PushToTalkOverlay's UIResponder touch overrides (see file
// for full saga of 7 attempts). Keep this comment as a forensic note
// for anyone who comes back here wondering why we're so paranoid.
