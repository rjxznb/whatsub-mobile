import SwiftUI

/// Identifies a tapped highlight phrase for the per-word 释义 sheet. A fresh UUID
/// per tap so `.sheet(item:)` re-presents even for the same phrase.
struct WordGloss: Identifiable {
    let id = UUID()
    let word: String
    let translation: String?
    let note: String?
}

/// A quick, read-only 释义 box for ONE tapped highlight phrase — shown when the
/// user single-taps a highlighted word (which intercepts the seek). Medium-detent
/// sheet; responsive.
struct GlossSheet: View {
    let gloss: WordGloss
    @Environment(\.dismiss) private var dismiss

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
}
