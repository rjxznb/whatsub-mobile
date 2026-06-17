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
/// user single-taps a highlighted word (which intercepts the seek). Medium-detent
/// sheet; responsive.
struct GlossSheet: View {
    let gloss: WordGloss
    @Environment(\.dismiss) private var dismiss
    /// Local state for the 加入暂存 button — `false` until the user taps it,
    /// after which the button label flips to ✓ 已加入 and disables. The
    /// sheet stays open so the user can keep reading the gloss or tap 完成
    /// when they're ready. The dedicated state (vs. checking the store)
    /// keeps things snappy and works even before PendingPhraseStore has a
    /// chance to write through.
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(gloss.word)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.whatsubHighlight)
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
        .presentationDetents([.medium])
    }

    /// 加入待同步暂存 — one-tap collect. Builds a PendingPhrase from
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
                Image(systemName: saved ? "checkmark.circle.fill" : "tray.and.arrow.down")
                Text(saved ? "已加入暂存" : "加入待同步暂存")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(saved ? Color.green : Color.whatsubAccent)
        .disabled(saved)
    }

    private func performSave() {
        guard let ctx = gloss.saveContext, !saved else { return }
        let trimmedNote = (gloss.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMeaning = (gloss.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = PendingPhrase(
            id: UUID(),
            entryId: ctx.entryId,
            videoTitle: ctx.videoTitle,
            youtubeId: ctx.youtubeId,
            phraseRaw: gloss.word,
            contextSentence: ctx.contextSentence,
            meaningZh: trimmedMeaning.isEmpty ? nil : trimmedMeaning,
            usageNote: trimmedNote.isEmpty ? nil : trimmedNote,
            timestampSec: ctx.timestampSec,
            collectedAt: Date().timeIntervalSince1970
        )
        PendingPhraseStore.shared.add(pending)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        saved = true
    }
}
