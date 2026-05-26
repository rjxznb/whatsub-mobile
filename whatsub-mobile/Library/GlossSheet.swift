import SwiftUI

/// A quick, read-only 释义 peek for a cue's AI-highlighted phrases — the light
/// "what does this mean?" lookup (distinct from the collect card). Presented as a
/// medium-height sheet; responsive (ScrollView + wrapping text).
struct GlossSheet: View {
    let cue: Cue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(cue.text).font(.system(size: 18, weight: .medium)).foregroundStyle(.whatsubInk)
                    if !cue.translation.isEmpty {
                        Text(cue.translation).font(.system(size: 15)).foregroundStyle(.whatsubInkMuted)
                    }
                    ForEach(cue.highlightWords, id: \.self) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(w).font(.headline).foregroundStyle(.whatsubHighlight)
                            if let t = cue.highlightTranslations[w], !t.isEmpty {
                                Text(t).font(.subheadline).foregroundStyle(.whatsubInk)
                            }
                            if let n = cue.keyNotes[w], !n.isEmpty {
                                Text(n).font(.callout).foregroundStyle(.whatsubInkSoft)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
                    }
                    if cue.highlightWords.isEmpty {
                        Text("这句没有标注的重点短语。").font(.footnote).foregroundStyle(.whatsubInkMuted)
                    }
                }
                .padding(16)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("释义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
