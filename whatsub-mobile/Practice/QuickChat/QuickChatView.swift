import SwiftUI
import AVFoundation
import Speech
import UIKit

/// QuickChat root sheet. The product surface of spec §6.5.
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
                VStack(spacing: 0) {
                    headerChips
                    transcriptScroll
                    inputBar
                }
                if vm.phase == .done {
                    QuickChatSummaryView(
                        phrases: phrases,
                        completed: vm.completedPhrases,
                        notes: vm.perPhraseLastNote,
                        onPlayAgain: { dismiss() },     // re-pick from CorpusView entry
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
        }
        .task {
            await requestPermissions()
            if !showCompliance { await vm.start() }
        }
        .onChange(of: showCompliance) { showing in
            // After the user dismisses the compliance gate, start the dialogue.
            if !showing, vm.turns.isEmpty { Task { await vm.start() } }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { vm.pause() }
            else if vm.phase == .paused { vm.resume() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            // Phone call / Siri / etc. — pause for safety.
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { vm.pause() }
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
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    // ---- transcript ----
    @ViewBuilder
    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
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
                        .id(turn.id)
                    }
                    if case .thinking = vm.phase {
                        ProgressView().tint(.whatsubAccent).padding(.leading, 12)
                    }
                    if case .error(let msg) = vm.phase {
                        Text(msg).font(.caption).foregroundStyle(.red).padding()
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .onChange(of: vm.turns.last?.assistantText ?? "") { _ in
                withAnimation { proxy.scrollTo(vm.turns.last?.id, anchor: .bottom) }
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
            HStack(spacing: 12) {
                micButton
                Button { typingMode = true } label: {
                    Image(systemName: "keyboard").foregroundStyle(.whatsubAccent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.whatsubBg)
        }
    }

    @ViewBuilder
    private var micButton: some View {
        switch micPhase {
        case .idle:
            Button { Task { await startCountdown() } } label: {
                Label("按麦说", systemImage: "mic.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.whatsubAccent)
            .disabled(vm.phase != .idle)
        case .countdown:
            Text("\(countdown)…").font(.title2.weight(.bold)).foregroundStyle(.whatsubAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubAccent.opacity(0.15)))
        case .recording:
            Button { stopRecording() } label: {
                Label("停止", systemImage: "stop.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.red)
        case .transcribing:
            HStack { ProgressView().tint(.whatsubAccent); Text("识别中…").font(.subheadline) }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
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
            // 20-second hard cap (sentences are short).
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

    // ---- youtube replay (best-effort: only youtube + timestamp) ----
    private func youtubeOpener(for p: SessionPhrase) -> (() -> Void)? {
        // ⚠️ `extractYouTubeID` is a free function (see Corpus/YouTubeID.swift).
        guard p.sourceKind == "youtube",
              let ts = p.sourceTimestampSec,
              let videoID = extractYouTubeID(p.sourceURL) else { return nil }
        return {
            // Just open the canonical youtu.be URL with t= so the system browser
            // (or YouTube app, if installed) jumps to the right second.
            let url = URL(string: "https://youtu.be/\(videoID)?t=\(Int(ts))")!
            UIApplication.shared.open(url)
        }
    }
}
