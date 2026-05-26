import SwiftUI
import UIKit

/// 收藏卡 — opened by long-pressing a subtitle cue. The English sentence is
/// selectable (pick any word/phrase, highlighted or not); 加入 saves the selection
/// (or the whole sentence if nothing is selected) plus the user's note into this
/// video's notebook. The AI 释义 of any highlight is shown as reference.
struct CollectSheet: View {
    let cue: Cue
    let entryId: String
    let videoTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhrase = ""
    @State private var note = ""

    private var phraseToSave: String {
        let trimmed = selectedPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? cue.text : trimmed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sentenceCard
                    if !cue.highlightWords.isEmpty { glossCard }
                    noteField
                    Text("将保存：\(phraseToSave)")
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("收藏到词汇本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入") { save() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var sentenceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("划选要收藏的词 / 短语").font(.caption).foregroundStyle(.whatsubInkMuted)
                Spacer()
                if !selectedPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("用整句") { selectedPhrase = "" }
                        .font(.caption).foregroundStyle(.whatsubAccent)
                }
            }
            SelectableTextView(text: cue.text) { sel in selectedPhrase = sel }
                .frame(minHeight: 44)
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
