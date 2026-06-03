import SwiftUI
import AVFoundation
import Speech
import UIKit
import CoreHaptics

/// Identifiable wrapper for sheet(item:) with String payload.
private struct TranslationTarget: Identifiable {
    let id = UUID()
    let text: String
}

/// QuickChat root sheet. Siri-style auto-listen voice loop:
///
/// 1. Sheet opens → compliance gate → vm.start() (LLM opens scene + TTS plays)
/// 2. TTS done → auto-enter .listening with VoiceActivityRecorder
/// 3. VAD detects speech → red orb; user finishes → transcribe + submit
/// 4. LLM streams reply → TTS plays → loop back to step 2
/// 5. 15s silence with no speech → end session
struct QuickChatView: View {
    let phrases: [SessionPhrase]
    let suggestedTag: String?

    @StateObject private var vm: QuickChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showCompliance: Bool
    @State private var stuckPhrase: SessionPhrase?
    @State private var showTranscript: Bool = false
    @State private var showCloseConfirm: Bool = false
    @State private var translatePresented: TranslationTarget?
    @State private var micPermissionDenied = false

    @AppStorage("quickchat.premium-voice-hint.shown") private var premiumHintShown: Bool = false
    @State private var showPremiumHint: Bool = false

    // VAD state
    @StateObject private var vadCoordinator = VADCoordinator()

    // Push-to-talk state (builds 237+). Replaced the previous auto-VAD +
    // typing-mode UI: typing is gone (user explicitly asked to force voice
    // input — the keyboard handling was too brittle in this layout, and
    // forcing voice doubles as a 强迫 mechanism for English practice).
    // Recording is now gated on a long-press DragGesture on the orb.
    @State private var isOrbPressed: Bool = false
    /// Sharp "thunk" on press — .rigid is the closest UIImpactFeedback gives
    /// to a key-down click. .light on release marks the release without
    /// competing with the press.
    private let pressHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let releaseHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var continuousHaptic = ContinuousHaptic()

    init(phrases: [SessionPhrase], suggestedTag: String?, maxTurns: Int? = 5,
         progressStore: ProductionProgressStore = ProductionProgressStore(),
         settings: LlmSettings = LlmSettingsStore.load()) {
        if phrases.isEmpty {
            print("[QuickChatView] WARNING: initialized with 0 phrases — UI will look empty")
        }
        self.phrases = phrases
        self.suggestedTag = suggestedTag
        let client = ChatCompletionsClient(settings: settings)
        let systemPrompt = QuickChatPrompts.systemPrompt(phrases: phrases, suggestedTag: suggestedTag)
        let engine = ConversationEngine(client: client, systemPrompt: systemPrompt)
        _vm = StateObject(wrappedValue: QuickChatViewModel(
            phrases: phrases, suggestedTag: suggestedTag,
            progressStore: progressStore,
            engineDriver: .live(engine),
            maxTurns: maxTurns
        ))
        _showCompliance = State(initialValue: !QuickChatComplianceGate.hasAcknowledged)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.whatsubBg
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    headerChips.padding(.top, 6)
                    Spacer(minLength: 0)
                    VoiceOrbView(state: orbState,
                                 audioLevel: vadCoordinator.audioLevel,
                                 isPressed: isOrbPressed)
                        .contentShape(Circle())
                        .gesture(orbPressGesture)
                    Spacer().frame(height: 18)
                    LyricTickerView(
                        onTranslate: { translatePresented = TranslationTarget(text: $0) },
                        onReport: { ReportMessageSheet.openMailReport(message: $0) }
                    )
                    Spacer().frame(height: 12)
                    // Live ASR transcript: while the user is holding the orb
                    // and there's already partial text, show that in place of
                    // the status hint so the user can verify their words are
                    // being captured in real time. The transcript text auto-
                    // wraps with growing height — keeps the layout clean and
                    // gives the user a clear signal "I'm hearing you say X".
                    if isOrbPressed && !vadCoordinator.liveTranscript.isEmpty {
                        Text(vadCoordinator.liveTranscript)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.whatsubInk)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .frame(minHeight: 22)
                            .transition(.opacity)
                    } else {
                        Text(statusText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.whatsubInkMuted)
                            .frame(minHeight: 22)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    if case .error(let msg) = vm.phase {
                        errorBanner(msg)
                            .padding(.top, 8)
                            .padding(.horizontal, 16)
                    }
                    Spacer(minLength: 0)
                }
                // First-turn loading overlay (2026-06-03): the opening AI
                // turn typically takes 2-5 s for the DeepSeek round-trip
                // before TTS starts. Without this overlay the user sees a
                // silent orb showing nothing (orb's .thinking visual is
                // subtle), can't press it (gesture is guarded on
                // vm.phase == .idle), and concludes the app is broken.
                // Show an explicit loading screen until the first dialog
                // text arrives.
                if vm.turns.isEmpty || (vm.turns.first?.assistantText.isEmpty == true) {
                    firstTurnLoadingOverlay
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.2),
                                   value: vm.turns.first?.assistantText.isEmpty)
                }
                if vm.phase == .done {
                    QuickChatSummaryView(
                        phrases: phrases,
                        completed: vm.completedPhrases,
                        notes: vm.perPhraseLastNote,
                        onPlayAgain: { dismiss() },
                        onClose: { dismiss() }
                    )
                    .background(Color.whatsubBg.ignoresSafeArea())
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomControls
                    .background(Color.whatsubBg)
            }
            .navigationTitle("对话陪练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        // If conversation hasn't started yet, dismiss immediately.
                        if vm.turns.isEmpty {
                            vadCoordinator.cancel()
                            Speaker.releaseSession()
                            dismiss()
                        } else {
                            showCloseConfirm = true
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showTranscript = true } label: {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(.whatsubAccent)
                    }
                    .accessibilityLabel("显示对话文字")
                    .disabled(vm.turns.isEmpty)
                }
            }
            .sheet(isPresented: $showCompliance) {
                QuickChatComplianceGate(presenting: $showCompliance)
                    .presentationDetents([.medium])
            }
            .sheet(item: $stuckPhrase) { p in
                QuickChatStuckCardView(
                    phrase: p,
                    onPlayOriginal: youtubeOpener(for: p),
                    onDismiss: { stuckPhrase = nil }
                )
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showTranscript) {
                transcriptDrawer.presentationDetents([.medium, .large])
            }
            .sheet(item: $translatePresented) { target in
                BubbleTranslationView(original: target.text)
                    .presentationDetents([.medium, .large])
            }
            .alert("结束这局练习？", isPresented: $showCloseConfirm) {
                Button("继续练习", role: .cancel) { }
                Button("结束", role: .destructive) {
                    vadCoordinator.cancel()
                    Speaker.stop()
                    Task {
                        await vm.endSession()
                        Speaker.releaseSession()
                        dismiss()
                    }
                }
            } message: {
                Text("已经用对的短语会保存到掌握度记录。")
            }
            .alert("英语朗读更自然", isPresented: $showPremiumHint) {
                Button("我知道了") {
                    premiumHintShown = true
                }
            } message: {
                Text("iOS 系统自带的「Premium / Enhanced」神经语音听起来更自然。可以到\n设置 → 辅助功能 → 朗读内容 → 语音 → 英语\n下载一个标有 Premium 的语音（例如 Ava 或 Evan），下次进入对话陪练就会自动使用。")
            }
        }
        .task {
            await requestPermissions()
            // IMPORTANT: spawn vm.start() in a DETACHED Task — do NOT `await`
            // it inside .task's body. SwiftUI's .task modifier cancels its
            // own body when the view re-renders in certain ways (vm.phase
            // change → @Published fires → view body recomputes → .task
            // closure considered "new"). On build 223 this caused chat()'s
            // URLSession.data() await to be cancelled mid-flight (~50ms in)
            // and surface as "网络失败：已取消" before DeepSeek could reply.
            // Detaching the work survives view re-renders.
            if !showCompliance { Task { await vm.start() } }
            // One-time hint about premium voices.
            if !premiumHintShown && !Speaker.hasPremiumEnglishVoice {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showPremiumHint = true
            }
        }
        .onChange(of: showCompliance) { showing in
            if !showing, vm.turns.isEmpty { Task { await vm.start() } }
        }
        // (Auto-listen orchestration removed in builds 237+ — recording is
        // now driven entirely by the orb's long-press gesture.)
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                vm.pause()
                vadCoordinator.cancel()
            } else if vm.phase == .paused {
                vm.resume()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                vm.pause()
                vadCoordinator.cancel()
            }
        }
        .onDisappear { vadCoordinator.cancel() }
    }

    // ---- push-to-talk orchestration (builds 237+) ----

    /// Long-press DragGesture on the orb. minimumDistance 0 so it fires
    /// the instant the user touches the orb (no drag required); `.onChanged`
    /// detects the touch-down on the first invocation and `.onEnded` the
    /// release. We track our own `isOrbPressed` flag instead of relying on
    /// gesture state because: (1) we need to ignore touches during AI's
    /// reply (vm.phase != .idle); (2) the haptic + recorder start should
    /// only fire on the TRANSITION from not-pressed to pressed, not every
    /// poll.
    private var orbPressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isOrbPressed,
                      vm.phase == .idle,
                      !vm.turns.isEmpty,
                      !micPermissionDenied else { return }
                isOrbPressed = true
                pressHaptic.impactOccurred(intensity: 1.0)        // sharp thunk
                continuousHaptic.start()                          // sustained rumble
                startPushToTalk()
            }
            .onEnded { _ in
                guard isOrbPressed else { return }
                isOrbPressed = false
                releaseHaptic.impactOccurred(intensity: 0.55)     // gentle release
                continuousHaptic.stop()
                endPushToTalk()
            }
    }

    private func startPushToTalk() {
        vadCoordinator.start(
            onSpeechDetected: { /* not used in push-to-talk mode */ },
            onSpeechEnded: { transcript, backupURL in
                Task { await self.handlePushToTalkEnded(transcript: transcript, backupURL: backupURL) }
            },
            onNoSpeechTimeout: { /* not used — caller controls timing */ }
        )
    }

    private func endPushToTalk() {
        vadCoordinator.endRecording()
    }

    private func handlePushToTalkEnded(transcript: String, backupURL: URL?) async {
        if let backupURL { try? FileManager.default.removeItem(at: backupURL) }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty transcript: silently no-op (user released too fast, or mic
        // captured no speech). Orb returns to idle + "push me" reappears.
        guard !text.isEmpty else { return }
        await vm.submitUserInput(text)
    }

    // ---- derived state ----

    /// Full-screen overlay shown while we wait for the first AI turn (the
    /// opening scene). Sits on top of the orb area so the user can't try to
    /// press the not-yet-ready orb. Auto-dismisses the moment the first
    /// dialogue chunk arrives (turns[0].assistantText becomes non-empty).
    private var firstTurnLoadingOverlay: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            VStack(spacing: 22) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.whatsubAccent)
                    .scaleEffect(1.6)
                Text("AI 正在准备开场…")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.whatsubInk)
                Text("第一次进入需要 2-5 秒，准备好就开始对话")
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private var orbState: VoiceOrbView.OrbState {
        // In push-to-talk mode, the press gesture is the source of truth.
        if isOrbPressed { return .recording }
        switch vm.phase {
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .recording: return .recording
        default: return .idle
        }
    }

    private var statusText: String {
        if isOrbPressed { return "正在听你说…" }
        switch vm.phase {
        case .thinking: return "AI 正在想…"
        case .speaking: return "AI 正在说…"
        case .recording: return "正在听你说…"
        case .paused: return "已暂停"
        case .error(let msg): return msg
        case .summarizing, .done: return ""
        case .listening: return ""
        case .idle:
            if vm.turns.isEmpty { return "准备开始…" }
            if micPermissionDenied { return "未授权麦克风，去 设置 → whatSub 打开" }
            return "按住球说话"
        }
    }

    // ---- chips ----
    // Builds 237+ wrap the row in a horizontal ScrollView and drop the
    // truncation marker. Long phrases (e.g. "speak louder so that it can
    // hear you better") used to render as "speak louder s…" with no way
    // to see the rest; user can now swipe to see the full chip text in
    // one swipe. Tap-to-open-detail-card is still wired below.
    private var headerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(phrases) { p in
                    Button { stuckPhrase = p } label: {
                        HStack(spacing: 4) {
                            Image(systemName: vm.completedPhrases.contains(p.phraseNormalized) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(vm.completedPhrases.contains(p.phraseNormalized) ? .green : .whatsubInkFaint)
                            Text(p.phraseRaw)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(.whatsubInk)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.whatsubBgElev))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    // ---- bottom controls (voice-only, builds 237+) ----
    //
    // Typing mode + the keyboard icon were removed: the TextField +
    // safeAreaInset + axis:.vertical combo had recurring keyboard-visibility
    // bugs across builds 226-234, and forcing voice input doubles as
    // English-practice pressure. Only the 结束 button remains down here;
    // the actual "talk" UI is the orb's long-press gesture.
    private var bottomControls: some View {
        HStack(spacing: 12) {
            Button {
                vadCoordinator.cancel()
                Task { await vm.endSession() }
            } label: {
                Text("结束")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.whatsubBgElev))
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 28).padding(.top, 12)
    }

    // ---- transcript drawer (full history) ----
    @ViewBuilder
    private var transcriptDrawer: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            if !turn.userText.isEmpty {
                                bubble(turn.userText, isUser: true)
                                    .contextMenu {
                                        Button {
                                            translatePresented = TranslationTarget(text: turn.userText)
                                        } label: { Label("显示中文", systemImage: "character.bubble") }
                                    }
                            }
                            if !turn.assistantText.isEmpty {
                                bubble(turn.assistantText, isUser: false)
                                    .contextMenu {
                                        Button {
                                            translatePresented = TranslationTarget(text: turn.assistantText)
                                        } label: { Label("显示中文", systemImage: "character.bubble") }
                                        Button {
                                            ReportMessageSheet.openMailReport(message: turn.assistantText)
                                        } label: { Label("上报这条回复", systemImage: "exclamationmark.bubble") }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("对话文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showTranscript = false }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 30) }
            Text(text).font(.system(size: 16)).foregroundStyle(.whatsubInk).padding(10)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(isUser ? Color.whatsubAccent.opacity(0.18) : Color.whatsubBgElev))
            if !isUser { Spacer(minLength: 30) }
        }
    }

    @ViewBuilder
    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("对话失败").font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubInk)
                Text(msg).font(.footnote).foregroundStyle(.whatsubInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if msg.contains("LLM 设置") || msg.contains("API Key") || msg.contains("notConfigured") {
                    Text("提示：到「我的 → LLM 设置」填入 DeepSeek 等服务的 API Key。")
                        .font(.caption2).foregroundStyle(.whatsubAccent).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
    }

    // ---- permissions ----
    private func requestPermissions() async {
        let mic: Bool
        if #available(iOS 17.0, *) {
            mic = await AVAudioApplication.requestRecordPermission()
        } else {
            mic = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { st in cont.resume(returning: st == .authorized) }
        }
        // Without mic + speech permissions the orb's push-to-talk path can't
        // function. Typing fallback was removed in builds 237+ (voice-only
        // policy), so we just flag and surface a status. The orb tap then
        // becomes a no-op (see orbPressGesture's micPermissionDenied guard).
        if !(mic && speech) { micPermissionDenied = true }
    }

    // ---- youtube replay ----
    private func youtubeOpener(for p: SessionPhrase) -> (() -> Void)? {
        guard p.sourceKind == "youtube",
              let ts = p.sourceTimestampSec,
              let videoID = extractYouTubeID(p.sourceURL) else { return nil }
        return {
            let url = URL(string: "https://youtu.be/\(videoID)?t=\(Int(ts))")!
            UIApplication.shared.open(url)
        }
    }
}

/// Owns the VoiceActivityRecorder and exposes `speechActive` as @Published so
/// the view's `orbState` updates when VAD onset/offset fires. Lives only while
/// the QuickChatView is on screen.
@MainActor
final class VADCoordinator: ObservableObject {
    @Published var speechActive: Bool = false
    /// Smoothed 0..1 audio level for the orb's real-time pulse.
    @Published var audioLevel: Float = 0
    /// Live partial transcript while the user is talking — used by the view
    /// to render "what you're saying" in real time. Cleared on start().
    @Published var liveTranscript: String = ""
    private let recorder = VoiceActivityRecorder()
    /// Fast attack — when voice rises, EMA snaps up in 1-2 frames (~30-60ms).
    /// User feedback wanted dramatic + immediate response when they start speaking.
    private let attackAlpha: Float = 0.7
    /// Slow release — when voice falls, EMA decays gently over ~400ms.
    /// This creates the "balloon-inflate-and-slow-deflate" feel.
    private let releaseAlpha: Float = 0.15

    func start(onSpeechDetected: @escaping () -> Void,
               onSpeechEnded: @escaping (_ transcript: String, _ backupURL: URL?) -> Void,
               onNoSpeechTimeout: @escaping () -> Void) {
        speechActive = false
        liveTranscript = ""
        recorder.onSpeechDetected = { [weak self] in
            Task { @MainActor in
                self?.speechActive = true
                onSpeechDetected()
            }
        }
        recorder.onSpeechEnded = { [weak self] transcript, backupURL in
            Task { @MainActor in
                self?.speechActive = false
                self?.audioLevel = 0
                self?.liveTranscript = ""
                onSpeechEnded(transcript, backupURL)
            }
        }
        recorder.onNoSpeechTimeout = { [weak self] in
            Task { @MainActor in
                self?.speechActive = false
                self?.audioLevel = 0
                self?.liveTranscript = ""
                onNoSpeechTimeout()
            }
        }
        recorder.onLevelUpdate = { [weak self] raw in
            Task { @MainActor in
                guard let self else { return }
                // Asymmetric envelope: fast on rise (dramatic), slow on fall (smooth).
                let alpha = raw > self.audioLevel ? self.attackAlpha : self.releaseAlpha
                self.audioLevel = (1 - alpha) * self.audioLevel + alpha * raw
            }
        }
        recorder.onPartialTranscript = { [weak self] text in
            Task { @MainActor in
                self?.liveTranscript = text
            }
        }
        do {
            try recorder.start()
        } catch VoiceActivityError.audioHardwareNotReady {
            // Hardware still settling from a category swap. Reset visible
            // state — the user can press again in a moment. Silent fail
            // here is correct: a banner would be jarring on a quick
            // double-tap.
            speechActive = false
            audioLevel = 0
        } catch {
            // Other startup failures (rare): also silent. The orb will go
            // back to idle on the next gesture release and the user will
            // see the "press me" label again.
            speechActive = false
            audioLevel = 0
        }
    }

    func cancel() {
        recorder.cancel()
        speechActive = false
        audioLevel = 0
    }

    /// Explicit end-of-turn signal for push-to-talk (builds 237+). Caller
    /// releases the orb; we tell the recorder to finalize, which fires
    /// onSpeechEnded with the live transcript.
    func endRecording() {
        recorder.endRecording()
    }
}

/// Sustained low-frequency rumble while the user holds the orb (push-to-talk).
/// Uses CoreHaptics' advanced player so we can start/stop on demand without
/// recreating a one-shot pattern each time. Falls back to silent no-ops on
/// devices that don't support haptics (iPad, simulator) — the visual + audio
/// feedback carries the press in those cases.
final class ContinuousHaptic {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    /// Cache supportsHaptics — the call is cheap but querying once is cleaner.
    private let isSupported: Bool

    init() {
        isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func start() {
        guard isSupported else { return }
        do {
            if engine == nil {
                let e = try CHHapticEngine()
                e.isAutoShutdownEnabled = true
                e.resetHandler = { [weak self] in
                    // Engine reset (e.g. backgrounded). Drop our player so
                    // the next start() rebuilds cleanly.
                    self?.player = nil
                }
                engine = e
            }
            try engine?.start()
            // Continuous event: moderate intensity, low sharpness = a soft
            // hum that says "actively recording" without being intrusive.
            // 30 s matches the recorder's hardCapSec — if the user holds
            // past the cap, recording ends and we stop() the haptic anyway.
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                       parameters: [intensity, sharpness],
                                       relativeTime: 0,
                                       duration: 30)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let p = try engine?.makeAdvancedPlayer(with: pattern)
            try p?.start(atTime: 0)
            player = p
        } catch {
            // Best-effort — never trip the UI on a haptic failure.
        }
    }

    func stop() {
        guard isSupported else { return }
        try? player?.stop(atTime: 0)
        player = nil
    }
}
