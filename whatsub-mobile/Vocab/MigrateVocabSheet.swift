import SwiftUI

/// Shown when deleting a video whose notebook is non-empty: decide what happens to
/// its saved phrases before the video is removed. `onChoose(target)` — target is a
/// destination book id (`VocabStore.stagingKey` for 暂存区, or another video's id),
/// or `nil` to delete the phrases along with the video.
struct MigrateVocabSheet: View {
    let videoTitle: String
    let count: Int
    let candidates: [LibraryListItem]   // other videos to merge into
    var onChoose: (_ target: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                List {
                    Section {
                        Button { choose(VocabStore.stagingKey) } label: {
                            Label("迁移到暂存区", systemImage: "tray.and.arrow.down")
                                .foregroundStyle(.whatsubInk)
                        }
                    } header: {
                        Text("「\(videoTitle)」有 \(count) 个收藏短语，删除视频前先：")
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    if !candidates.isEmpty {
                        Section("迁移到其他视频") {
                            ForEach(candidates) { v in
                                Button { choose(v.id) } label: {
                                    Text(v.title).foregroundStyle(.whatsubInk).lineLimit(2)
                                }
                            }
                        }
                        .listRowBackground(Color.whatsubBgElev)
                    }

                    Section {
                        Button(role: .destructive) { choose(nil) } label: {
                            Label("一起删除（不保留短语）", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("删除视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func choose(_ target: String?) {
        onChoose(target)
        dismiss()
    }
}
