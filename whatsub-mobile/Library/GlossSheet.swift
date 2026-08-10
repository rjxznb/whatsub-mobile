import SwiftUI

/// Identifies a tapped highlight phrase for the per-word 释义 sheet. A fresh UUID
/// per tap so `.sheet(item:)` re-presents even for the same phrase.
struct WordGloss: Identifiable {
    let id = UUID()
    let word: String
    let translation: String?
    let note: String?
    /// Optional save context. When non-nil, the GlossSheet shows a 加入暂存
    /// button that builds a `PendingPhrase` with this metadata. When nil
    /// (import preview, where the entry doesn't exist yet), the button is
    /// hidden so users don't see a non-functional CTA.
    let saveContext: SaveContext?

    struct SaveContext {
        let entryId: String
        let videoTitle: String
        let youtubeId: String?
        let contextSentence: String
        let timestampSec: Double
    }
}

/// A quick, read-only 释义 box for ONE tapped highlight phrase — shown when the
/// user single-taps a highlighted word (which intercepts the seek). Compact
/// bottom sheet with pronunciation and one-tap pending collection.
struct GlossSheet: View {
    let gloss: WordGloss
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: HighlightWordCardModel

    init(gloss: WordGloss) {
        self.gloss = gloss
        _model = StateObject(wrappedValue: HighlightWordCardModel(gloss: gloss))
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
                    if gloss.saveContext != nil {
                        saveButton
                            .padding(.top, 8)
                    }
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
        }
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
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
        .disabled(model.saved)
    }

    private func performSave() {
        guard model.collect() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
