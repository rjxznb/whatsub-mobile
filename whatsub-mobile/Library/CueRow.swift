import SwiftUI

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool
    /// Seek to this cue — fired by tapping a NON-highlight word, the Chinese line,
    /// or the row's empty area.
    let onTapCue: () -> Void
    /// Tapping a highlighted phrase shows its 释义 (and does NOT seek). Carries the
    /// phrase + its translation/note looked up from the cue.
    let onTapHighlight: (_ phrase: String, _ translation: String?, _ note: String?) -> Void
    /// Long-press anywhere on the cue → collect card.
    let onCollect: () -> Void

    private struct WordToken: Identifiable {
        let id: Int
        let text: String
        let phrase: String?   // the highlight phrase this word belongs to (nil = normal)
    }

    /// Positional runs (from splitForHighlights) split into per-word tokens so the
    /// line wraps by word AND each highlighted word is independently tappable. A
    /// highlight run's `.text` is the matched phrase = a key into the cue's
    /// keyNotes / highlightTranslations.
    private var tokens: [WordToken] {
        var out: [WordToken] = []
        var id = 0
        for run in splitForHighlights(cue.text, highlights: cue.highlightWords) {
            for w in run.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                out.append(WordToken(id: id, text: w, phrase: run.highlight ? run.text : nil))
                id += 1
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 5, lineSpacing: 6) {
                ForEach(tokens) { tok in
                    let isHL = tok.phrase != nil
                    Text(tok.text)
                        .font(.system(size: 22, weight: isHL ? .semibold : .regular))
                        .foregroundColor(isHL ? .whatsubHighlight : (isCurrent ? .whatsubInk : .whatsubInkSoft))
                        .underline(isHL, color: .whatsubHighlight)
                        .onTapGesture {
                            if let p = tok.phrase {
                                onTapHighlight(p, cue.highlightTranslations[p], cue.keyNotes[p])
                            } else {
                                onTapCue()
                            }
                        }
                }
            }
            Text(cue.translation)
                .font(.system(size: 16))
                .foregroundStyle(isCurrent ? .whatsubInkSoft : .whatsubInkMuted)
                .onTapGesture { onTapCue() }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        // Tap on empty area = seek (highlighted words / Chinese line capture their
        // own taps above). Long-press anywhere = collect.
        .onTapGesture { onTapCue() }
        .onLongPressGesture { onCollect() }
    }
}
