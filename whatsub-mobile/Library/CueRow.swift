import SwiftUI

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool
    let onTapCue: () -> Void
    /// Long-press → context menu: 收藏到词汇本 (this) + 查看释义 (below).
    let onCollect: () -> Void
    /// Long-press → 查看释义 (quick read-only gloss of the cue's highlights).
    let onShowGloss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            englishLine
            Text(cue.translation)
                .font(.system(size: 16))
                .foregroundStyle(isCurrent ? .whatsubInkSoft : .whatsubInkMuted)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Each cue is its own subtle card so segments read as distinct blocks
        // against the pure-black page. Current cue: accent tint + accent border.
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrent ? Color.whatsubAccent.opacity(0.18) : Color.whatsubBgElev)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isCurrent ? Color.whatsubAccent.opacity(0.6) : Color.white.opacity(0.06),
                              lineWidth: isCurrent ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTapCue() }
        // Long-press → choose: quick 释义 peek vs collect into the notebook.
        // (Tap still seeks; the two intents no longer fight over one gesture.)
        .contextMenu {
            if !cue.highlightWords.isEmpty {
                Button { onShowGloss() } label: { Label("查看释义", systemImage: "text.book.closed") }
            }
            Button { onCollect() } label: { Label("收藏到词汇本", systemImage: "bookmark") }
        }
    }

    private var englishLine: some View {
        // SwiftUI Text concatenation can't hit-test individual runs, so:
        //   tap whole row = seek (handled by parent); long-press = show the
        //   first highlight's note. Per-word tap would need a custom wrapping
        //   layout — deferred (YAGNI for v1).
        let runs = splitForHighlights(cue.text, highlights: cue.highlightWords)
        return runs.reduce(Text("")) { acc, run in
            if run.highlight {
                return acc + Text(run.text)
                    .foregroundColor(.whatsubHighlight)
                    .underline()
                    .fontWeight(.semibold)
            } else {
                return acc + Text(run.text).foregroundColor(isCurrent ? .whatsubInk : .whatsubInkSoft)
            }
        }
        .font(.system(size: 22))
    }
}
