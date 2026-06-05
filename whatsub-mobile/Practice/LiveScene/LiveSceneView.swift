import SwiftUI
import PhotosUI

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

    /// Live press latch for the orb gesture (NOT vm.phase). Two reasons
    /// QuickChat uses this same pattern + we MUST match it:
    /// 1. The gesture is a computed property below so SwiftUI keeps the
    ///    SAME gesture instance alive across view re-renders. If we
    ///    instead built it inline inside a function each render (as I
    ///    did in d7e501a / 0b5e6ca), SwiftUI swaps gesture instances mid-
    ///    press and the original instance's `.onEnded` never fires.
    /// 2. Using a @State Bool as the latch (read AND written inside the
    ///    same closure) keeps press/release semantics explicit + lets
    ///    onChanged be idempotent without depending on vm phase timing.
    @State private var isOrbPressed: Bool = false

    /// Rolling on-screen log of the last few gesture/recorder events,
    /// rendered as a tiny pill at the top of the view (so the user can
    /// see what's happening WITHOUT plugging into Xcode / Console.app).
    /// Stops growing after ~6 lines so the overlay stays a single short
    /// strip. Strip out once the orb is provably stable.
    @State private var debugLog: [String] = []
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
        ZStack(alignment: .top) {
            Color.whatsubBg.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Debug overlay (TEMPORARY — strip with the @State debugLog +
            // logDebug() once the orb gesture is provably stable). Sits
            // at the very top in a tiny mono font so events are visible
            // on-device without plugging into Xcode / Console.app.
            if !debugLog.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(debugLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(.whatsubInkMuted)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.whatsubBgElev.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12).padding(.top, 4)
            }
        }
        .sheet(isPresented: $showCamera) {
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
        //
        // Also safety-reset the orb-press latch if phase moved AWAY from
        // .recording for any reason that wasn't a clean user-release (e.g.
        // the recorder hit its 30s hardCap while the user was still
        // holding). Without this the orb would stay visually pressed
        // forever after the recorder finished on its own.
        .onChange(of: phaseKey(vm.phase)) { newKey in
            hintLevel = .none
            if newKey != "recording" && isOrbPressed {
                isOrbPressed = false
            }
        }
        // Don't tear down on .onDisappear — tab switches fire it too, and
        // we want the prompt + captured image to persist when the user
        // comes back to this tab. The recorder cleans up its own audio
        // session on each endRecording() call, so a tab switch mid-prompt
        // leaks nothing. (If the user is HOLDING the orb during a tab
        // switch — rare — the recorder's 30s hardCap or the next press's
        // teardown cleans up; not worth special-casing.)
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

    // MARK: - orb (push-to-talk)

    // (SwiftUI orbPressGesture removed 2026-06-05 — 4 attempts at
    // making SwiftUI DragGesture / LongPressGesture work all hit a
    // silent-cancellation bug. UIKit `PushToTalkOverlay` (in orbBlock
    // below) handles touches directly via UILongPressGestureRecognizer
    // and works first try.)

    /// Append a line to the debug overlay, trim to last 6 lines. Strip
    /// this + the overlay rendering once the gesture is provably stable.
    private func logDebug(_ msg: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100))
        debugLog.append("[\(stamp)] \(msg)")
        // Bumped to 12 (was 6) — the lifecycle + UIControl + raw-touch
        // overrides emit 3-4 events per press cycle on average, and a
        // 6-line cap was rotating out earlier events too fast for
        // diagnosis.
        if debugLog.count > 12 {
            debugLog.removeFirst(debugLog.count - 12)
        }
    }

    /// Push-to-talk orb. **7th** attempt — finally below SwiftUI's
    /// gesture system entirely. PushToTalkOverlay overrides
    /// UIResponder's touchesBegan/Ended/Cancelled directly; the OS
    /// guarantees a paired ENDED-or-CANCELLED for every BEGAN, so
    /// release is reliable. The 6 prior attempts (DragGesture inline /
    /// closure-vm-phase / computed+@State / no-ScrollView /
    /// UILongPressGestureRecognizer / Button+ButtonStyle) all had
    /// release silently swallowed by SwiftUI's gesture coordinator at
    /// various layers; user confirmed the symptom every time.
    ///
    /// Layout: VoiceOrbView is the visual layer with
    /// `.allowsHitTesting(false)` so SwiftUI doesn't even consider it
    /// for hit testing. PushToTalkOverlay is the topmost hit target
    /// — its raw UIView reliably receives touches at the orb's
    /// position.
    @ViewBuilder
    private func orbBlock(isRecording: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                VoiceOrbView(
                    state: isOrbPressed ? .recording : .idle,
                    audioLevel: vm.audioLevel,
                    isPressed: isOrbPressed,
                    baseSize: 110
                )
                .allowsHitTesting(false)   // hand all touches to overlay
                PushToTalkOverlay(
                    onPress: {
                        guard !isOrbPressed, case .ready = vm.phase else { return }
                        isOrbPressed = true
                        vm.startRecording()
                        logDebug("→ start phase=\(phaseKey(vm.phase))")
                    },
                    onRelease: {
                        guard isOrbPressed else { return }
                        isOrbPressed = false
                        vm.endRecording()
                        logDebug("→ end   phase=\(phaseKey(vm.phase))")
                    },
                    onLog: { msg in logDebug(msg) }
                )
                .frame(width: 210, height: 210)
            }
            Text(isOrbPressed ? "松开结束" : "按住说英语")
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
