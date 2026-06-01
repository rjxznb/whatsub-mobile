import SwiftUI
import AVFoundation

/// Lists every installed English TTS voice with a quality badge, lets the user
/// preview each one, and pin a specific voice for QuickChat. Pinned voice is
/// persisted in UserDefaults (`Speaker.pinnedVoiceDefaultsKey`) and honored by
/// `Speaker.pickVoice` before its auto-pick logic.
struct VoiceSettingsView: View {
    @AppStorage(Speaker.pinnedVoiceDefaultsKey) private var pinnedIdentifier: String = ""
    /// The list is fetched once on appear. Voices are stable across the lifetime
    /// of this view (they only change when the user visits System Settings).
    @State private var voices: [AVSpeechSynthesisVoice] = []
    /// Identifier currently previewing (for ProgressView in the row).
    @State private var previewingId: String?

    var body: some View {
        List {
            Section {
                autoRow
                ForEach(voices, id: \.identifier) { voice in
                    voiceRow(voice)
                }
            } header: {
                Text("英语语音").foregroundStyle(.whatsubInkMuted)
            } footer: {
                footerExplainer
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.whatsubBg.ignoresSafeArea())
        .navigationTitle("语音设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            voices = Speaker.availableEnglishVoices()
        }
    }

    // ---- rows ----

    private var autoRow: some View {
        Button {
            pinnedIdentifier = ""
        } label: {
            HStack {
                Image(systemName: pinnedIdentifier.isEmpty ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(pinnedIdentifier.isEmpty ? Color.whatsubAccent : Color.whatsubInkFaint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动").font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubInk)
                    Text("按品质择优 (Premium → Enhanced → Default)")
                        .font(.caption).foregroundStyle(.whatsubInkMuted)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.whatsubBgElev)
        .buttonStyle(.plain)
    }

    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        let isPinned = voice.identifier == pinnedIdentifier
        return HStack(spacing: 12) {
            Button {
                pinnedIdentifier = voice.identifier
            } label: {
                Image(systemName: isPinned ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPinned ? Color.whatsubAccent : Color.whatsubInkFaint)
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(voice.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.whatsubInk)
                    qualityBadge(voice.quality)
                }
                Text(voice.language)
                    .font(.caption2.weight(.medium)).foregroundStyle(.whatsubInkFaint)
            }
            Spacer()
            previewButton(voice)
        }
        .listRowBackground(Color.whatsubBgElev)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func qualityBadge(_ quality: AVSpeechSynthesisVoiceQuality) -> some View {
        switch quality {
        case .premium:
            badge(text: "Premium", color: .green)
        case .enhanced:
            badge(text: "Enhanced", color: .blue)
        default:
            badge(text: "Default", color: .gray)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 0.8))
    }

    @ViewBuilder
    private func previewButton(_ voice: AVSpeechSynthesisVoice) -> some View {
        if previewingId == voice.identifier {
            ProgressView().controlSize(.small).tint(.whatsubAccent)
        } else {
            Button {
                preview(voice)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.whatsubAccent)
                    .padding(10)
                    .background(Color.whatsubBg, in: Circle())
            }
            .buttonStyle(.borderless)
        }
    }

    private func preview(_ voice: AVSpeechSynthesisVoice) {
        previewingId = voice.identifier
        Speaker.stop()
        // Bypass pinned-voice logic for the preview — we want THIS specific voice
        // to play even if a different one is pinned. Use a transient AVSpeechSynthesizer
        // call with the explicit voice.
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "Hello! Welcome to whatsub. Let's practice some English together.")
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        synth.speak(utterance)
        // ~3.5s after speak, clear preview state (no delegate hook needed for this
        // simple UX; if user taps another row, that's fine, previewingId updates).
        let id = voice.identifier
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run {
                if previewingId == id { previewingId = nil }
            }
        }
    }

    // ---- footer ----

    @ViewBuilder
    private var footerExplainer: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("关于语音品质").font(.caption.weight(.semibold)).foregroundStyle(.whatsubInk)
                Text(
                    "iOS 把每种语言的 TTS 分成三档：\n" +
                    "• Default — 预装但偏机器音\n" +
                    "• Enhanced — 下载后更自然\n" +
                    "• Premium — Siri 同款神经语音，听感最自然\n\n" +
                    "Premium / Enhanced 都要在系统设置手动下载（一次性 ~500MB）。下完后 whatsub 会自动用最好的那个。"
                )
                .font(.caption).foregroundStyle(.whatsubInkMuted)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("下载更自然的语音").font(.caption.weight(.semibold)).foregroundStyle(.whatsubInk)
                Text("iOS 设置 → 辅助功能 → 朗读内容 → 语音 → 英语 → 找标着 Premium 的（例如 Ava、Evan、Zoe）→ 下载")
                    .font(.caption).foregroundStyle(.whatsubInkMuted)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开 whatsub 系统设置", systemImage: "gear")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.whatsubAccent)
                .padding(.top, 2)
                Text("（iOS 不允许 app 直接跳到「朗读内容」深路径，请进系统设置后手动找。）")
                    .font(.caption2).foregroundStyle(.whatsubInkFaint)
            }
        }
        .padding(.top, 8)
    }
}
