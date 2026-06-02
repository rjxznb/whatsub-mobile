import SwiftUI
import AVFoundation
import Speech
import UIKit

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
    @State private var typingMode: Bool = false
    @State private var micPermissionDenied = false

    @AppStorage("quickchat.premium-voice-hint.shown") private var premiumHintShown: Bool = false
    @State private var showPremiumHint: Bool = false

    // VAD state
    @StateObject private var vadCoordinator = VADCoordinator()

    /// Keyboard height above the home-indicator safe area. Driven by
    /// UIResponder.keyboardWill{Show,Hide}Notification. iOS 16's automatic
    /// `safeAreaInset(edge: .bottom)` keyboard-avoidance does NOT fire reliably
    /// inside NavigationStack with a `TextField(axis: .vertical)` — the inset
    /// content stays anchored to the home indicator and the field hides
    /// behind the keyboard (see screenshot 2026-06-02). Manual padding makes
    /// it ride correctly.
    @State private var keyboardOffset: CGFloat = 0
    @FocusState private var typingFieldFocused: Bool

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
                // Keyboard dismissal policy (user feedback 2026-06-02):
                // - Taps do NOT dismiss (would steal focus on stray taps / orb).
                // - A downward swipe on the background DOES dismiss, mimicking
                //   the standard iMessage "drag down to hide keyboard" gesture.
                Color.whatsubBg
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 24)
                            .onChanged { v in
                                if v.translation.height > 24 && typingFieldFocused {
                                    typingFieldFocused = false
                                }
                            }
                    )
                VStack(spacing: 0) {
                    headerChips.padding(.top, 6)
                    Spacer(minLength: 0)
                    VoiceOrbView(state: orbState, audioLevel: vadCoordinator.audioLevel)
                    Spacer().frame(height: 18)
                    LyricTickerView(
                        onTranslate: { translatePresented = TranslationTarget(text: $0) },
                        onReport: { ReportMessageSheet.openMailReport(message: $0) }
                    )
                    Spacer().frame(height: 12)
                    Text(statusText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.whatsubInkMuted)
                        .frame(minHeight: 22)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    if case .error(let msg) = vm.phase {
                        errorBanner(msg)
                            .padding(.top, 8)
                            .padding(.horizontal, 16)
                    }
                    Spacer(minLength: 0)
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
                    .padding(.bottom, keyboardOffset)
                    .animation(.easeOut(duration: 0.22), value: keyboardOffset)
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
            if !showCompliance { await vm.start() }
            // One-time hint about premium voices.
            if !premiumHintShown && !Speaker.hasPremiumEnglishVoice {
                // Delay slightly so it doesn't compete with compliance gate.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showPremiumHint = true
            }
        }
        .onChange(of: showCompliance) { showing in
            if !showing, vm.turns.isEmpty { Task { await vm.start() } }
        }
        // Watch VM phase transitions to drive the auto-listen loop.
        .onChange(of: vm.phase) { newPhase in
            handlePhaseChange(newPhase)
        }
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
        // Keyboard tracking — manual because iOS 16 NavigationStack +
        // safeAreaInset(.bottom) + TextField(axis:.vertical) doesn't auto-ride.
        // We compute (keyboard frame height − bottom safe-area inset) so the
        // padding accounts for the home indicator already covered by the safe
        // area, avoiding a double-margin gap above the keyboard.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let scenes = UIApplication.shared.connectedScenes
            let bottomInset = (scenes.compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }?.safeAreaInsets.bottom) ?? 0
            keyboardOffset = max(0, frame.height - bottomInset)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardOffset = 0
        }
        .onDisappear { vadCoordinator.cancel() }
    }

    // ---- auto-listen orchestration ----

    /// Called whenever vm.phase changes. After AI finishes TTS (we detect by
    /// transitioning from .speaking/.thinking to .idle with TTS not speaking
    /// any more), enter listening mode.
    private func handlePhaseChange(_ newPhase: QuickChatViewModel.Phase) {
        guard !typingMode, !micPermissionDenied else { return }
        guard newPhase == .idle else { return }
        // The VM goes to .idle after a turn completes. Wait briefly for the TTS
        // queue to drain, then enter listening.
        Task {
            // Poll until Speaker is done speaking the queued sentences.
            for _ in 0..<150 {  // 150 × 100ms = 15s max wait
                if !Speaker.isSpeaking { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Small grace before opening mic — avoid catching the speaker tail.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard vm.phase == .idle, !typingMode else { return }
            vm.enterListening()
            await startVAD()
        }
    }

    private func startVAD() async {
        vadCoordinator.start(
            onSpeechDetected: { /* orb auto-updates via orbState */ },
            onSpeechEnded: { url in
                Task { await self.handleVADSpeechEnded(url) }
            },
            onNoSpeechTimeout: {
                Task {
                    await vm.handleNoSpeechTimeout()
                    if vm.phase != .done { vm.exitListening() }
                }
            }
        )
    }

    private func handleVADSpeechEnded(_ url: URL) async {
        vm.exitListening()    // back to .idle while we transcribe
        vm.resetNoSpeechCounter()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let r = recognizer, r.isAvailable else { return }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        do {
            let text: String = try await withCheckedThrowingContinuation { cont in
                var done = false
                r.recognitionTask(with: req) { result, error in
                    if done { return }
                    if let error { done = true; cont.resume(throwing: error); return }
                    if let result, result.isFinal {
                        done = true
                        cont.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
            try? FileManager.default.removeItem(at: url)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await vm.submitUserInput(text)
            } else {
                // Empty transcription — treat as no-speech, restart VAD.
                if vm.phase == .idle, !typingMode { vm.enterListening(); await startVAD() }
            }
        } catch {
            // ASR failed — restart listening.
            if vm.phase == .idle, !typingMode { vm.enterListening(); await startVAD() }
        }
    }

    // ---- derived state ----

    private var orbState: VoiceOrbView.OrbState {
        if vadCoordinator.speechActive { return .recording }
        switch vm.phase {
        case .listening: return .idle           // listening but no speech yet — gentle pulse
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .recording: return .recording
        default: return .idle
        }
    }

    private var statusText: String {
        switch vm.phase {
        case .listening:
            return vadCoordinator.speechActive ? "正在听你说…" : "请开始说话…"
        case .thinking: return "AI 正在想…"
        case .speaking: return "AI 正在说…"
        case .recording: return "正在听你说…"
        case .paused: return "已暂停"
        case .error(let msg): return msg
        case .summarizing, .done: return ""
        case .idle: return vm.turns.isEmpty ? "准备开始…" : "稍等…"
        }
    }

    // ---- chips ----
    private var headerChips: some View {
        HStack(spacing: 8) {
            ForEach(phrases) { p in
                Button { stuckPhrase = p } label: {
                    HStack(spacing: 4) {
                        Image(systemName: vm.completedPhrases.contains(p.phraseNormalized) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vm.completedPhrases.contains(p.phraseNormalized) ? .green : .whatsubInkFaint)
                        Text(p.phraseRaw)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(.whatsubInk)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.whatsubBgElev))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    // ---- bottom controls (no mic button anymore) ----
    @ViewBuilder
    private var bottomControls: some View {
        if typingMode || micPermissionDenied {
            HStack(alignment: .bottom, spacing: 8) {
                // axis:.vertical + lineLimit(1...6) lets the field grow with
                // multi-line input (up to ~6 lines). Beyond that, the inner
                // text scrolls — the safeAreaInset above keeps the latest
                // typed line visible above the keyboard. HStack alignment
                // .bottom anchors the send buttons to the bottom of the
                // (possibly tall) TextField, mirroring iMessage.
                TextField("打字回应…", text: $vm.typedInput, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
                    .focused($typingFieldFocused)
                Button {
                    let text = vm.typedInput
                    vm.typedInput = ""
                    Task { await vm.submitUserInput(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2).foregroundStyle(.whatsubAccent)
                }
                .disabled(vm.typedInput.trimmingCharacters(in: .whitespaces).isEmpty || vm.phase != .idle)
                if !micPermissionDenied {
                    Button {
                        typingMode = false
                        // After leaving typing mode, immediately enter listening
                        // for the user's next turn (don't wait for next AI reply).
                        if vm.phase == .idle, !vm.turns.isEmpty {
                            vm.enterListening()
                            Task { await startVAD() }
                        }
                    } label: {
                        Image(systemName: "mic.fill").foregroundStyle(.whatsubAccent)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.whatsubBg)
        } else {
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
                Button {
                    typingMode = true
                    vm.exitListening()
                    vadCoordinator.cancel()
                } label: {
                    Image(systemName: "keyboard")
                        .font(.title3).foregroundStyle(.whatsubAccent)
                        .padding(10)
                        .background(Circle().fill(Color.whatsubBgElev))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 28).padding(.top, 12)
        }
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
        if !(mic && speech) { micPermissionDenied = true; typingMode = true }
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
    private let recorder = VoiceActivityRecorder()
    /// Fast attack — when voice rises, EMA snaps up in 1-2 frames (~30-60ms).
    /// User feedback wanted dramatic + immediate response when they start speaking.
    private let attackAlpha: Float = 0.7
    /// Slow release — when voice falls, EMA decays gently over ~400ms.
    /// This creates the "balloon-inflate-and-slow-deflate" feel.
    private let releaseAlpha: Float = 0.15

    func start(onSpeechDetected: @escaping () -> Void,
               onSpeechEnded: @escaping (URL) -> Void,
               onNoSpeechTimeout: @escaping () -> Void) {
        speechActive = false
        recorder.onSpeechDetected = { [weak self] in
            Task { @MainActor in
                self?.speechActive = true
                onSpeechDetected()
            }
        }
        recorder.onSpeechEnded = { [weak self] url in
            Task { @MainActor in
                self?.speechActive = false
                self?.audioLevel = 0
                onSpeechEnded(url)
            }
        }
        recorder.onNoSpeechTimeout = { [weak self] in
            Task { @MainActor in
                self?.speechActive = false
                self?.audioLevel = 0
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
        do {
            try recorder.start()
        } catch {
            // Mic failed — silently abort; view will eventually time out / user will tap keyboard.
        }
    }

    func cancel() {
        recorder.cancel()
        speechActive = false
        audioLevel = 0
    }
}
