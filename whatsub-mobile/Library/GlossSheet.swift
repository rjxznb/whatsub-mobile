import SwiftUI

/// Identifies a tapped highlight phrase for the per-word 释义 sheet. A fresh UUID
/// per tap so `.sheet(item:)` re-presents even for the same phrase.
struct WordGloss: Identifiable {
    let id = UUID()
    let word: String
    let translation: String?
    let note: String?
    let sourceContext: SourceContext?
    let collectionState: CollectionState

    struct SourceContext {
        let title: String
        let analysisFingerprint: String
        let profile: VideoContextProfile?
        let cues: [Cue]
        let currentCueIndex: Int
    }

    struct SaveContext {
        let entryId: String
        let videoTitle: String
        let youtubeId: String?
        let contextSentence: String
        let timestampSec: Double
    }

    enum CollectionState {
        case collectable(SaveContext)
        case alreadyCollected
        case unavailable
    }
}

/// A quick, read-only 释义 box for ONE tapped highlight phrase — shown when the
/// user single-taps a highlighted word (which intercepts the seek). Compact
/// bottom sheet with pronunciation and one-tap pending collection.
struct GlossSheet: View {
    typealias EnsureProfile = DeepGlossViewModel.EnsureProfile
    static let compactDetent: PresentationDetent = .height(340)

    let gloss: WordGloss
    let ensureProfile: EnsureProfile?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: HighlightWordCardModel
    @StateObject private var deepGlossModel: DeepGlossViewModel
    @State private var selectedDetent: PresentationDetent = Self.compactDetent

    init(
        gloss: WordGloss,
        settings: LlmSettings = LlmSettingsStore.load(),
        token: String = KeychainStore.load()?.sessionToken ?? "",
        ensureProfile: EnsureProfile? = nil
    ) {
        self.gloss = gloss
        self.ensureProfile = ensureProfile
        _model = StateObject(wrappedValue: HighlightWordCardModel(gloss: gloss))
        _deepGlossModel = StateObject(wrappedValue: DeepGlossViewModel(
            settings: settings,
            token: token
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(gloss.word)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.whatsubHighlight)
                            if let ipa = model.ipa {
                                Text(ipa)
                                    .font(.subheadline)
                                    .foregroundStyle(.whatsubInkMuted)
                            }
                        }
                        Spacer(minLength: 8)
                        Button {
                            model.replay()
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(Color.whatsubAccent.opacity(0.14), in: Circle())
                        }
                        .accessibilityLabel("再次播放发音")
                    }
                    if let t = gloss.translation, !t.isEmpty {
                        Text(t).font(.title3).foregroundStyle(.whatsubInk)
                    }
                    if let n = gloss.note, !n.isEmpty {
                        Text(n).font(.body).foregroundStyle(.whatsubInkSoft)
                    }
                    if (gloss.translation?.isEmpty ?? true) && (gloss.note?.isEmpty ?? true) {
                        Text("（暂无释义）").font(.footnote).foregroundStyle(.whatsubInkMuted)
                    }
                    if showsCollectionControl {
                        saveButton
                            .padding(.top, 8)
                    }
                    deepGlossContent
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("释义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .task(id: gloss.id) {
            model.appear()
        }
        .onDisappear {
            model.disappear()
            deepGlossModel.cancel()
        }
        .presentationDetents([Self.compactDetent, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
    }

    private var showsCollectionControl: Bool {
        switch gloss.collectionState {
        case .collectable, .alreadyCollected:
            return true
        case .unavailable:
            return false
        }
    }

    /// 收藏 — one-tap pending collection. Builds a PendingPhrase from
    /// the gloss + saveContext and writes it to the shared local store.
    /// Same path CollectSheet.save() uses (just without the per-cue word
    /// selection + AI note step) — the phrase IS the highlighted word,
    /// the note IS the gloss already shown above, so there's nothing left
    /// to choose.
    @ViewBuilder
    private var saveButton: some View {
        Button {
            performSave()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.saved ? "checkmark.circle.fill" : "bookmark.fill")
                Text(model.saved ? "已收藏" : "收藏")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.saved ? Color.green : Color.whatsubAccent)
        .disabled(!model.canCollect)
    }

    @ViewBuilder
    private var deepGlossContent: some View {
        switch deepGlossModel.phase {
        case .idle:
            deepGlossButton(title: "深度解读", systemImage: "sparkles")
        case .preparingContext:
            loadingRow("正在准备视频语境…")
        case .loading:
            loadingRow("正在深度解读…")
        case .loaded:
            if let result = deepGlossModel.result {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(
                        Array(DeepGlossPresentation.visibleSections(for: result).enumerated()),
                        id: \.offset
                    ) { _, section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.whatsubInk)
                            Text(section.content)
                                .font(.body)
                                .foregroundStyle(.whatsubInkSoft)
                        }
                    }
                }
            }
        case .analysisChanged:
            retryBlock("字幕解析已更新，请基于最新字幕重试。")
        case .fingerprintUnavailable:
            retryBlock("视频解析版本还没准备好，请刷新后重试。")
        case .failed(let failure):
            retryBlock(failure.message)
        }
    }

    private func deepGlossButton(title: String, systemImage: String) -> some View {
        Button {
            selectedDetent = .large
            Task {
                await deepGlossModel.load(gloss: gloss, ensureProfile: ensureProfile)
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(.bordered)
        .tint(.whatsubAccent)
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.whatsubInkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func retryBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
            deepGlossButton(title: "重试深度解读", systemImage: "arrow.clockwise")
        }
    }

    private func performSave() {
        guard model.collect() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
