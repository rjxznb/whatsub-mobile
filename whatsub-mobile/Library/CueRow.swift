import SwiftUI

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool
    /// Seek to this cue — fired by tapping a NON-highlight word, the Chinese line,
    /// or the row's empty area.
    let onTapCue: () -> Void
    /// Tapping a highlighted phrase shows its 释义 (and does NOT seek). Carries the
    /// phrase + its translation/note looked up from the cue + the cue itself so
    /// the gloss sheet can build a `PendingPhrase` if the user hits 收藏 (uses
    /// `cue.text` as context sentence + `cue.time` as timestamp).
    let onTapHighlight: (_ phrase: String, _ translation: String?, _ note: String?, _ cue: Cue) -> Void
    /// Long-press → 收藏 entry from the contextMenu.
    let onCollect: () -> Void
    /// Long-press → 跟读 (shadowing) entry from the contextMenu. Defaults to no-op
    /// so call sites that don't expose practice (e.g., the import preview before
    /// the entry is saved) can omit it.
    var onShadow: () -> Void = {}
    /// Long-press → 听抄 (cloze) entry from the contextMenu. Defaults to no-op.
    var onCloze: () -> Void = {}

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
                                onTapHighlight(p, cue.highlightTranslations[p], cue.keyNotes[p], cue)
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
        // Tap on empty area = seek (highlighted words / Chinese line capture
        // their own taps above). Long-press = native contextMenu with three
        // practice/save actions. (Pre-2026-05-29 long-press jumped straight to
        // the 收藏 sheet — now 收藏 is one of three siblings alongside the
        // new 跟读 + 听抄 modes.)
        .onTapGesture { onTapCue() }
        .contextMenu {
            Button { onCollect() } label: { Label("收藏到词汇本", systemImage: "bookmark") }
            Button { onShadow() } label: { Label("跟读练习", systemImage: "mic.circle") }
            Button { onCloze() } label: { Label("听抄练习", systemImage: "ear") }
            Divider()
            Button {
                UIPasteboard.general.string = cue.text
            } label: { Label("复制原文", systemImage: "doc.on.doc") }
            if !cue.translation.isEmpty {
                Button {
                    UIPasteboard.general.string = cue.translation
                } label: { Label("复制译文", systemImage: "doc.on.doc") }
                Button {
                    UIPasteboard.general.string = "\(cue.text)\n\(cue.translation)"
                } label: { Label("复制双语", systemImage: "doc.on.doc.fill") }
            }
        }
    }
}
