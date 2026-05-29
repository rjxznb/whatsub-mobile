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
    /// Local playback of the user's own recording for A/B comparison with the
    /// original cue. Lives only while the sheet is open; reset on retry +
    /// stopped on dismiss.
    @State private var playbackPlayer: AVAudioPlayer?
    @State private var isPlayingRecording = false

    enum Phase: Equatable {
        case idle
        case playingOriginal
        case countingDown
        case recording
        case transcribing
        case result
        case error(String)
    }

    init(cue: Cue, sharedPlayer: AVPlayer?, videoURL: URL?) {
        self.cue = cue
        self.videoURL = videoURL
        // Prefer the shared LibraryDetailView avPlayer if provided — no fresh
        // HTTP fetch, reuses the already-buffered video. Falls back to building
        // its own from the URL when no shared player is available.
        _audio = StateObject(wrappedValue: CueAudioPlayer(sharedPlayer: sharedPlayer, videoURL: videoURL))
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
            // Pre-buffer at this cue's time so the first 听原文 tap is fast.
            // Doesn't start playback (no audio yet) — just kicks off the OSS
            // byte-range fetch while user reads. Combined with the shared
            // player from LibraryDetailView, this is what makes practice
            // responsive on big videos (the cold-buffer case where the user
            // jumps straight to practice without playing the main video).
            if videoURL != nil { audio.preload(at: cue.time) }
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
                // Three-state play button: 听原文 (idle) → 加载中 (buffering)
                // → 暂停 (actually emitting audio). Tap during 加载中 cancels
                // the request — important when a big OSS video has a long
                // first buffer and the user changes their mind.
                Button { togglePlayCue() } label: { playCueLabel }
                .buttonStyle(.bordered)
                .tint(.whatsubAccent)
                .disabled(videoURL == nil || phase == .countingDown || phase == .recording || phase == .transcribing)

                recordButton
            }
            statusLine
        }
    }

    /// Shared label for the cue-audio play/pause button used in both the action
    /// area and the A/B compare row. Three states: idle / loading (spinner) /
    /// playing — matches CueAudioPlayer's isPlaying + isLoading.
    @ViewBuilder
    private var playCueLabel: some View {
        HStack(spacing: 6) {
            if audio.isLoading {
                ProgressView().controlSize(.small).tint(.whatsubAccent)
            } else {
                Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            }
            Text(audio.isLoading ? "加载中…" : (audio.isPlaying ? "暂停" : "听原文"))
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func togglePlayCue() {
        // Tap during loading cancels the request (.stop pauses + clears the
        // periodic time observer + KVO will flip isLoading back to false).
        if audio.isPlaying || audio.isLoading {
            audio.stop()
        } else {
            Task { await playOriginal() }
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
            // A/B compare row — tap one then the other to hear your pronunciation
            // against the original. 听原文 in the action area above stays usable
            // too; this duplicate places them side-by-side at the moment of review.
            HStack(spacing: 10) {
                Button {
                    stopRecordingPlayback()
                    togglePlayCue()
                } label: { playCueLabel.padding(.vertical, -4) }
                .buttonStyle(.bordered).tint(.whatsubAccent)
                .disabled(videoURL == nil)

                Button {
                    toggleRecordingPlayback()
                } label: {
                    Label(isPlayingRecording ? "暂停" : "听我的录音",
                          systemImage: isPlayingRecording ? "pause.circle.fill" : "play.circle.fill")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered).tint(.whatsubAccent)
                .disabled(recordingURL == nil)
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

    // --------------------------------------------------------- playback (A/B compare)

    private func toggleRecordingPlayback() {
        if isPlayingRecording {
            stopRecordingPlayback()
            return
        }
        guard let url = recordingURL else { return }
        // Stop the cue audio first so the two never overlap.
        audio.stop()
        // .playAndRecord session is still active from the recording step and
        // supports playback — no category switch needed. AVAudioPlayer reads
        // the local m4a from temp; no network, no recognition, no cost.
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            let dur = p.duration
            p.play()
            playbackPlayer = p
            isPlayingRecording = true
            // Cheap auto-stop without an AVAudioPlayerDelegate subclass — the
            // recording is at most 12s; flip the flag back when the duration
            // elapses (+200ms tail) so the button label restores.
            Task { [dur] in
                try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000) + 200_000_000)
                await MainActor.run {
                    // Only flip if the same playback is still active (user might
                    // have hit retry / closed the sheet in the meantime).
                    if isPlayingRecording { isPlayingRecording = false }
                }
            }
        } catch {
            // Non-critical — show nothing; user can hit "再试一次" if confused.
        }
    }

    private func stopRecordingPlayback() {
        playbackPlayer?.stop()
        playbackPlayer = nil
        isPlayingRecording = false
    }

    // -------------------------------------------------------------- reset/teardown

    private func resetForRetry() {
        stopRecordingPlayback()
        diff = nil
        transcribedText = ""
        phase = .idle
        // Don't delete the recording file yet — user may still want to play it
        // back briefly. stopAll() (on dismiss) handles full cleanup.
    }

    private func stopAll() {
        audio.stop()
        stopRecordingPlayback()
        recorder?.stop()
        recorder = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
    }
}
