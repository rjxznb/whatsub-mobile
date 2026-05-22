import SwiftUI

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool
    let onTapCue: () -> Void
    let onTapHighlight: (_ word: String, _ note: String?, _ translation: String?) -> Void

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
        .onLongPressGesture {
            if let first = cue.highlightWords.first {
                onTapHighlight(first, cue.keyNotes[first], cue.highlightTranslations[first])
            }
        }
    }
}
