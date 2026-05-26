import SwiftUI
import UIKit

/// 收藏卡 — opened by long-pressing a subtitle cue. The English sentence is shown
/// as tappable word chips: tap the word(s) you want (they highlight); the saved
/// phrase is those words (in sentence order), or the whole sentence if none are
/// tapped. Plus a free-form 笔记 field. The AI 释义 of any highlight is reference.
/// Chips reflow via FlowLayout, so the card fits any screen size.
struct CollectSheet: View {
    let cue: Cue
    let entryId: String
    let videoTitle: String

    @Environment(\.dismiss) private var dismiss
    private let tokens: [String]
    @State private var selected: Set<Int> = []
    @State private var note = ""

    init(cue: Cue, entryId: String, videoTitle: String) {
        self.cue = cue
        self.entryId = entryId
        self.videoTitle = videoTitle
        // Split on whitespace; hyphenated tokens ("back-to-back") stay one chip.
        self.tokens = cue.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    private var hasSelection: Bool { !selected.isEmpty }

    private var phraseToSave: String {
        if selected.isEmpty { return cue.text }
        return selected.sorted().map { tokens[$0] }.joined(separator: " ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    wordCard
                    if !cue.highlightWords.isEmpty { glossCard }
                    noteField
                    previewRow
                }
                .padding(16)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("收藏到词汇本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(hasSelection ? "加入" : "加入整句") { save() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var wordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasSelection ? "点词增减选择，再点「加入」" : "点句中的词来挑选要收藏的部分（或直接「加入整句」）")
                .font(.caption).foregroundStyle(.whatsubInkMuted)
            FlowLayout(spacing: 6, lineSpacing: 8) {
                ForEach(tokens.indices, id: \.self) { i in
                    let on = selected.contains(i)
                    Text(tokens[i])
                        .font(.system(size: 18, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : Color.whatsubInk)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(on ? Color.whatsubHighlight : Color.whatsubBgSoft)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture {
                            if on { selected.remove(i) } else { selected.insert(i) }
                        }
                }
            }
            if !cue.translation.isEmpty {
                Text(cue.translation).font(.system(size: 15)).foregroundStyle(.whatsubInkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    private var glossCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 释义参考").font(.caption).foregroundStyle(.whatsubInkMuted)
            ForEach(cue.highlightWords, id: \.self) { w in
                HStack(alignment: .top, spacing: 8) {
                    Text(w).font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubHighlight)
                    VStack(alignment: .leading, spacing: 2) {
                        if let t = cue.highlightTranslations[w], !t.isEmpty {
                            Text(t).font(.subheadline).foregroundStyle(.whatsubInk)
                        }
                        if let n = cue.keyNotes[w], !n.isEmpty {
                            Text(n).font(.caption).foregroundStyle(.whatsubInkSoft)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("笔记").font(.caption).foregroundStyle(.whatsubInkMuted)
            TextField("写点笔记（可留空）", text: $note, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgSoft))
                .foregroundStyle(.whatsubInk)
        }
    }

    private var previewRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("将保存：").font(.footnote).foregroundStyle(.whatsubInkMuted)
            Text(phraseToSave).font(.footnote.weight(.medium)).foregroundStyle(.whatsubHighlight)
            Spacer(minLength: 0)
            if hasSelection {
                Button("清空") { selected.removeAll() }.font(.caption).foregroundStyle(.whatsubAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let item = VocabItem(
            phrase: phraseToSave,
            sentenceEn: cue.text,
            translationZh: cue.translation,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            cueIndex: cue.index,
            sourceTitle: videoTitle
        )
        VocabStore.shared.add(item, to: entryId)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
