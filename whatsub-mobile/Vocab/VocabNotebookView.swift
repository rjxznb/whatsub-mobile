import SwiftUI

/// One video's vocab notebook (or the global 暂存区 when `entryId == stagingKey`).
/// Tap a row → jump to its cue (when `onJump` is provided and the item still has a
/// cueIndex); swipe to delete; leading-swipe to edit the note.
struct VocabNotebookView: View {
    let entryId: String
    let title: String
    /// Seek to a cue index + dismiss. nil for the staging area (no video context).
    var onJump: ((Int) -> Void)?

    @ObservedObject private var store = VocabStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: VocabItem?

    private var isStaging: Bool { entryId == VocabStore.stagingKey }
    private var items: [VocabItem] { store.items(for: entryId) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(items) { item in
                            row(item)
                                .listRowBackground(Color.whatsubBgElev)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let idx = item.cueIndex, let onJump { onJump(idx) }
                                }
                                .swipeActions(edge: .leading) {
                                    Button { editing = item } label: {
                                        Label("笔记", systemImage: "square.and.pencil")
                                    }.tint(.blue)
                                }
                        }
                        .onDelete { offsets in
                            let snapshot = items
                            for i in offsets where snapshot.indices.contains(i) {
                                store.remove(itemId: snapshot[i].id, from: entryId)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(isStaging ? "暂存区" : "词汇本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sheet(item: $editing) { item in NoteEditor(item: item, entryId: entryId) }
        }
    }

    private func row(_ item: VocabItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.phrase).font(.headline).foregroundStyle(.whatsubInk)
            if !item.note.isEmpty {
                Text(item.note).font(.subheadline).foregroundStyle(.whatsubInkSoft)
            }
            Text(item.sentenceEn).font(.caption).foregroundStyle(.whatsubInkMuted).lineLimit(2)
            if isStaging, let src = item.sourceTitle, !src.isEmpty {
                Text("来自：\(src)").font(.caption2).foregroundStyle(.whatsubInkFaint).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed").font(.system(size: 44)).foregroundStyle(.whatsubAccent)
            Text(isStaging ? "暂存区还是空的" : "这个视频还没有收藏的短语")
                .font(.headline).foregroundStyle(.whatsubInk)
            Text(isStaging
                 ? "删除视频时迁移过来的短语会出现在这里"
                 : "精读时长按某条字幕，在弹出的收藏卡里选词加入")
                .font(.footnote).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Edit one item's note.
private struct NoteEditor: View {
    let item: VocabItem
    let entryId: String
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(item: VocabItem, entryId: String) {
        self.item = item
        self.entryId = entryId
        _text = State(initialValue: item.note)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.phrase).font(.headline).foregroundStyle(.whatsubHighlight)
                    TextField("笔记", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgSoft))
                        .foregroundStyle(.whatsubInk)
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("编辑笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        VocabStore.shared.updateNote(
                            itemId: item.id, in: entryId,
                            note: text.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
        }
    }
}
