import SwiftUI
import AVFoundation
import Speech
import UIKit

/// QuickChat root sheet. Voice-first UI (豆包/ChatGPT-Voice feel):
/// the central pulsating orb is the primary interaction surface; chat
/// bubbles are hidden by default and accessible via the top-right
/// transcript drawer icon.
struct QuickChatView: View {
    let phrases: [SessionPhrase]
    let suggestedTag: String?

    @StateObject private var vm: QuickChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // Compliance gate
    @State private var showCompliance: Bool
    // Stuck card
    @State private var stuckPhrase: SessionPhrase?
    // Transcript drawer
    @State private var showTranscript: Bool = false
    // Input mode
    @State private var typingMode: Bool = false
    // Mic + ASR state
    @State private var micPhase: MicPhase = .idle
    @State private var countdown: Int = 0
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var micPermissionDenied = false

    enum MicPhase: Equatable {
        case idle, countdown, recording, transcribing
    }

    init(phrases: [SessionPhrase], suggestedTag: String?,
         progressStore: ProductionProgressStore = ProductionProgressStore(),
         settings: LlmSettings = LlmSettingsStore.load()) {
        // Defensive log — if a caller passes 0 phrases we want to surface that
        // immediately rather than render a blank sheet.
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
            engineDriver: .live(engine)
        ))
        _showCompliance = State(initialValue: !QuickChatComplianceGate.hasAcknowledged)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.whatsubBg.ignoresSafeArea()
                // -------- Voice-mode primary layout --------
                VStack(spacing: 0) {
                    headerChips
                        .padding(.top, 6)
                    Spacer(minLength: 0)
                    VoiceOrbView(state: orbState)
                    Spacer().frame(height: 24)
                    Text(statusText)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.whatsubInkMuted)
                        .frame(minHeight: 24)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    if case .error(let msg) = vm.phase {
                        errorBanner(msg)
                            .padding(.top, 8)
                            .padding(.horizontal, 16)
                    }
                    Spacer(minLength: 0)
                    inputBar
                }
                // -------- End-of-session summary overlay --------
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
            .navigationTitle("对话陪练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { Task { await vm.endSession(); dismiss() } }
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
                transcriptDrawer
                    .presentationDetents([.medium, .large])
            }
        }
        .task {
            await requestPermissions()
            if !showCompliance { await vm.start() }
        }
        .onChange(of: showCompliance) { showing in
            if !showing, vm.turns.isEmpty { Task { await vm.start() } }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { vm.pause() }
            else if vm.phase == .paused { vm.resume() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { vm.pause() }
        }
    }

    // ---- orb state + status text derived from VM + mic ----
    private var orbState: VoiceOrbView.OrbState {
        switch micPhase {
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .countdown, .idle:
            switch vm.phase {
            case .thinking: return .thinking
            case .speaking: return .speaking
            default: return .idle
            }
        }
    }

    private var statusText: String {
        switch micPhase {
        case .recording: return "正在听你说…"
        case .transcribing: return "识别中…"
        case .countdown: return "\(countdown)…"
        case .idle: break
        }
        switch vm.phase {
        case .thinking: return "AI 正在想…"
        case .speaking: return "AI 正在说…"
        case .paused: return "已暂停（点录音继续）"
        case .error(let msg): return msg
        case .summarizing, .done: return ""
        case .idle, .recording: return vm.turns.isEmpty ? "准备开始…" : "按下麦克风说话"
        }
    }

    // ---- header chips ----
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

    // ---- transcript drawer ----
    @ViewBuilder
    private var transcriptDrawer: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            if !turn.userText.isEmpty {
                                bubble(turn.userText, isUser: true)
                            }
                            if !turn.assistantText.isEmpty {
                                bubble(turn.assistantText, isUser: false)
                                    .contextMenu {
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
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.whatsubInk)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(isUser ? Color.whatsubAccent.opacity(0.18) : Color.whatsubBgElev))
            if !isUser { Spacer(minLength: 30) }
        }
    }

    // ---- input bar ----
    @ViewBuilder
    private var inputBar: some View {
        if micPermissionDenied || typingMode {
            HStack(spacing: 8) {
                TextField("打字回应…", text: $vm.typedInput, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
                Button {
                    let text = vm.typedInput
                    vm.typedInput = ""
                    Task { await vm.submitUserInput(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(.whatsubAccent)
                }
                .disabled(vm.typedInput.trimmingCharacters(in: .whitespaces).isEmpty || vm.phase != .idle)
                if !micPermissionDenied {
                    Button { typingMode = false } label: {
                        Image(systemName: "mic.fill").foregroundStyle(.whatsubAccent)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.whatsubBg)
        } else {
            HStack(spacing: 16) {
                micButton
                Button { typingMode = true } label: {
                    Image(systemName: "keyboard")
                        .font(.title3)
                        .foregroundStyle(.whatsubAccent)
                        .padding(10)
                        .background(Circle().fill(Color.whatsubBgElev))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 28).padding(.top, 12)
        }
    }

    @ViewBuilder
    private var micButton: some View {
        switch micPhase {
        case .idle:
            Button { Task { await startCountdown() } } label: {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.whatsubAccent)
            }
            .disabled(vm.phase != .idle)
        case .countdown:
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.whatsubAccent.opacity(0.5))
        case .recording:
            Button { stopRecording() } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)
            }
        case .transcribing:
            ProgressView()
                .controlSize(.large)
                .tint(.whatsubAccent)
                .frame(width: 56, height: 56)
        }
    }

    // ---- permissions + mic/ASR (adapted from ShadowSheet.swift) ----

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

    private func startCountdown() async {
        guard !micPermissionDenied else { return }
        micPhase = .countdown
        for n in stride(from: 3, through: 1, by: -1) {
            countdown = n
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        startRecording()
    }

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            micPhase = .idle
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qc-\(UUID().uuidString).m4a")
        recordingURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            micPhase = .recording
            Task { [weak r] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if r?.isRecording == true { await MainActor.run { stopRecording() } }
            }
        } catch {
            micPhase = .idle
        }
    }

    private func stopRecording() {
        recorder?.stop(); recorder = nil
        guard let url = recordingURL else { micPhase = .idle; return }
        micPhase = .transcribing
        Task { await transcribe(url) }
    }

    private func transcribe(_ url: URL) async {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let r = recognizer, r.isAvailable else {
            micPhase = .idle; typingMode = true
            return
        }
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
            micPhase = .idle
            await vm.submitUserInput(text)
        } catch {
            micPhase = .idle
        }
    }

    // ---- error banner ----
    @ViewBuilder
    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("对话失败").font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubInk)
                Text(msg).font(.footnote).foregroundStyle(.whatsubInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if msg.contains("LLM 设置") || msg.contains("API Key") || msg.contains("notConfigured") {
                    Text("提示：到「我的 → LLM 设置」填入 DeepSeek 等服务的 API Key。")
                        .font(.caption2).foregroundStyle(.whatsubAccent)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
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
