import SwiftUI

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool
    /// The English cue is already playable while its server-generated fields
    /// are still pending. Keep this deliberately quiet: hundreds of row-level
    /// spinners would be visually noisy and waste rendering work.
    var isAwaitingAnalysis: Bool = false
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

    private var cueText: CueTextPresentation {
        CueTextPresentation.make(text: cue.text, highlights: cue.highlightWords)
    }

    private var attributedCueText: AttributedString {
        var value = AttributedString()
        for run in cueText.runs {
            var piece = AttributedString(run.text)
            if let id = run.highlightID {
                piece.font = .system(size: 22, weight: .semibold)
                piece.foregroundColor = .whatsubHighlight
                piece.underlineStyle = .single
                piece.link = URL(string: "whatsub-highlight://\(id)")
            } else {
                piece.font = .system(size: 22)
                piece.foregroundColor = isCurrent ? .whatsubInk : .whatsubInkSoft
            }
            value.append(piece)
        }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attributedCueText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "whatsub-highlight",
                          let idText = url.host,
                          let id = Int(idText),
                          let phrase = cueText.highlightPhrase(id: id) else {
                        return .discarded
                    }
                    let lookupKey = cueText.highlightLookupKey(id: id)
                    let translation = lookupKey.flatMap { cue.highlightTranslations[$0] } ?? cue.highlightTranslations[phrase]
                    let note = lookupKey.flatMap { cue.keyNotes[$0] } ?? cue.keyNotes[phrase]
                    onTapHighlight(phrase, translation, note, cue)
                    return .handled
                })
            if isAwaitingAnalysis {
                Text("等待 AI")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.whatsubInkMuted)
                    .onTapGesture { onTapCue() }
            } else {
                Text(cue.translation)
                    .font(.system(size: 16))
                    .foregroundStyle(isCurrent ? .whatsubInkSoft : .whatsubInkMuted)
                    .onTapGesture { onTapCue() }
            }
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
