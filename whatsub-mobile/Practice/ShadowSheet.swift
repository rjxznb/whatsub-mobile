import SwiftUI
import AVFoundation
import Speech
import UIKit

/// 跟读 sheet. Flow:
///   1. cue text + 听原文 button (auto-plays once on appear)
///   2. 录音 button → 3-second countdown → records → 停止
///   3. transcribe via SFSpeechRecognizer → word-diff vs cue.text → show
///      per-word color + score + 再试一次 / 完成
///
/// All speech recognition is on-device (SFSpeechRecognizer with
/// `requiresOnDeviceRecognition = true` falls back to server if unavailable
/// for the locale — en-US is supported on-device since iOS 13). No backend.
struct ShadowSheet: View {
    let cue: Cue
    let videoURL: URL?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio: CueAudioPlayer
    @State private var phase: Phase = .idle
    @State private var countdown: Int = 0
    @State private var permissionDenied = false
    @State private var transcribedText: String = ""
    @State private var diff: DiffResult?
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var recordingStartedAt: Date?

    enum Phase: Equatable {
        case idle
        case playingOriginal
        case countingDown
        case recording
        case transcribing
        case result
        case error(String)
    }

    init(cue: Cue, videoURL: URL?) {
        self.cue = cue
        self.videoURL = videoURL
        // Build the cue player with whatever URL we have; if nil, the user
        // can still record + transcribe — they just won't hear the original.
        if let v = videoURL {
            _audio = StateObject(wrappedValue: CueAudioPlayer(videoURL: v))
        } else {
            // Dummy placeholder so the StateObject contract holds; play() will
            // be disabled in the UI when videoURL is nil.
            _audio = StateObject(wrappedValue: CueAudioPlayer(videoURL: URL(string: "file:///dev/null")!))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    cueCard
                    actionArea
                    if let diff { resultCard(diff) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("跟读练习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { stopAll(); dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task {
            // Request permissions early so the first 录音 tap doesn't hit the
            // OS prompt mid-countdown.
            await requestPermissions()
            // Auto-play the original once when the sheet opens — frames the
            // practice loop ("here's what to say").
            if videoURL != nil { await playOriginal() }
        }
        .onDisappear { stopAll() }
    }

    // ---------------------------------------------------------------- cue card

    private var cueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cue.text)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.whatsubInk)
            Text(cue.translation)
                .font(.system(size: 15))
                .foregroundStyle(.whatsubInkMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    // ---------------------------------------------------------------- actions

    @ViewBuilder
    private var actionArea: some View {
        if permissionDenied {
            permissionDeniedView
        } else {
            HStack(spacing: 12) {
                Button {
                    Task { await playOriginal() }
                } label: {
                    Label(audio.isPlaying ? "播放中…" : "听原文", systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.whatsubAccent)
                .disabled(videoURL == nil || phase == .countingDown || phase == .recording || phase == .transcribing)

                recordButton
            }
            statusLine
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        switch phase {
        case .countingDown:
            Text("\(countdown)…")
                .font(.title2.weight(.bold))
                .foregroundStyle(.whatsubAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubAccent.opacity(0.15)))
        case .recording:
            Button { stopRecording() } label: {
                Label("停止", systemImage: "stop.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .transcribing:
            HStack { ProgressView().tint(.whatsubAccent); Text("正在识别…").font(.subheadline).foregroundStyle(.whatsubInkMuted) }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
        default:
            Button { Task { await startCountdown() } } label: {
                Label("跟读", systemImage: "mic.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.whatsubAccent)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if case let .error(msg) = phase {
            Text(msg).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionDeniedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("需要麦克风 + 语音识别权限")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubInk)
            Text("到 设置 → whatSub 中开启「麦克风」和「语音识别」后即可使用跟读练习。")
                .font(.caption).foregroundStyle(.whatsubInkMuted)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.whatsubAccent)
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
    }

    // ----------------------------------------------------------------- result

    @ViewBuilder
    private func resultCard(_ d: DiffResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("识别结果").font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubInk)
                Spacer()
                Text("\(d.score) 分")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(scoreColor(d.score))
            }
            // Word-by-word coloring: match=green, miss=gray strikethrough,
            // extras shown below in muted with a "你多说了:" prefix.
            FlowLayout(spacing: 5, lineSpacing: 6) {
                ForEach(d.expected) { tok in
                    Text(tok.word)
                        .font(.system(size: 17, weight: tok.status == .match ? .semibold : .regular))
                        .foregroundStyle(tok.status == .match ? .green : .whatsubInkFaint)
                        .strikethrough(tok.status == .miss, color: .whatsubInkFaint)
                }
            }
            if !d.extras.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("多说:").font(.caption).foregroundStyle(.whatsubInkFaint)
                    Text(d.extras.map { $0.word }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.whatsubInkMuted)
                }
            }
            if !transcribedText.isEmpty {
                Text("你说的: \(transcribedText)")
                    .font(.caption).foregroundStyle(.whatsubInkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("再试一次") { resetForRetry() }
                    .buttonStyle(.bordered).tint(.whatsubAccent)
                Spacer()
                Button("完成") { stopAll(); dismiss() }
                    .buttonStyle(.borderedProminent).tint(.whatsubAccent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    private func scoreColor(_ s: Int) -> Color {
        if s >= 80 { return .green }
        if s >= 50 { return .whatsubAccent }
        return .whatsubHighlight
    }

    // ------------------------------------------------------- permission flow

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
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
        if !(mic && speech) { permissionDenied = true }
    }

    // ----------------------------------------------------------- play original

    private func playOriginal() async {
        guard videoURL != nil else { return }
        phase = .playingOriginal
        audio.play(from: cue.time, to: cue.endTime)
        // Wait through the cue duration so the button reflects 播放中.
        let dur = max(0.4, cue.endTime - cue.time)
        try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
        phase = .idle
    }

    // ------------------------------------------------------ countdown + record

    private func startCountdown() async {
        guard !permissionDenied else { return }
        diff = nil
        transcribedText = ""
        phase = .countingDown
        for n in stride(from: 3, through: 1, by: -1) {
            countdown = n
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        startRecording()
    }

    private func startRecording() {
        // Switch the audio session to record-capable. We use .playAndRecord so
        // a subsequent "听原文" still works without re-config.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            phase = .error("无法启用麦克风：\(error.localizedDescription)")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-\(UUID().uuidString).m4a")
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
            recordingStartedAt = Date()
            phase = .recording
            // Hard cap recording at 12s — cues are short, prevents runaway.
            Task { [weak r] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if r?.isRecording == true { await MainActor.run { stopRecording() } }
            }
        } catch {
            phase = .error("无法开始录音：\(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        // Guard against zero-length recordings (user tapped 停止 immediately).
        if let started = recordingStartedAt, Date().timeIntervalSince(started) < 0.4 {
            phase = .error("录音太短，请再试一次")
            return
        }
        guard let url = recordingURL else {
            phase = .error("录音丢失，请再试一次")
            return
        }
        phase = .transcribing
        Task { await transcribe(url) }
    }

    private func transcribe(_ url: URL) async {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let r = recognizer, r.isAvailable else {
            phase = .error("语音识别暂不可用（en-US）")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // Prefer on-device when available — privacy + offline.
        if r.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        do {
            let text: String = try await withCheckedThrowingContinuation { cont in
                var hasResumed = false
                r.recognitionTask(with: request) { result, error in
                    if hasResumed { return }
                    if let error {
                        hasResumed = true
                        cont.resume(throwing: error)
                        return
                    }
                    if let result, result.isFinal {
                        hasResumed = true
                        cont.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
            transcribedText = text
            diff = TextDiff.diff(expected: cue.text, actual: text)
            phase = .result
        } catch {
            phase = .error("识别失败：\(error.localizedDescription)")
        }
    }

    // -------------------------------------------------------------- reset/teardown

    private func resetForRetry() {
        diff = nil
        transcribedText = ""
        phase = .idle
    }

    private func stopAll() {
        audio.stop()
        recorder?.stop()
        recorder = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
    }
}
