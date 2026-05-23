import SwiftUI

struct ImportQueueView: View {
    @EnvironmentObject var appState: AppState
    @State private var items: [ImportQueueItem] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var retryingIds: Set<String> = []

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            List {
                if let loadError {
                    Text(loadError).foregroundStyle(.whatsubInkMuted)
                        .listRowBackground(Color.whatsubBgElev)
                } else if items.isEmpty && !loading {
                    Text("还没有推送到桌面的导入任务。")
                        .foregroundStyle(.whatsubInkMuted)
                        .listRowBackground(Color.whatsubBgElev)
                } else {
                    ForEach(sortedItems) { item in
                        row(item).listRowBackground(Color.whatsubBgElev)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
        .navigationTitle("导入队列")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var sortedItems: [ImportQueueItem] {
        items.sorted { $0.updatedAt > $1.updatedAt }
    }

    @ViewBuilder
    private func row(_ item: ImportQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.url).font(.subheadline).foregroundStyle(.whatsubInk).lineLimit(1)
            HStack(spacing: 8) {
                statusChip(item.status)
                Spacer()
                if item.status == "failed" {
                    Button {
                        Task { await retry(item) }
                    } label: {
                        if retryingIds.contains(item.id) {
                            ProgressView().tint(.whatsubAccent)
                        } else {
                            Label("重试", systemImage: "arrow.clockwise").font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.whatsubAccent)
                    .disabled(retryingIds.contains(item.id))
                }
            }
            if item.status == "failed", let err = item.error, !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.whatsubInkMuted)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusChip(_ status: String) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case "pending": return ("待处理", .whatsubInkMuted)
            case "processing": return ("处理中", .whatsubAccent)
            case "done": return ("已完成", .green)
            case "failed": return ("失败", .whatsubHighlight)
            default: return (status, .whatsubInkMuted)
            }
        }()
        Text(label)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func load() async {
        guard let token = appState.session?.sessionToken else { loadError = "请先登录"; return }
        loading = true; loadError = nil
        do { items = try await WhatsubAPI.shared.listImportQueue(token: token) }
        catch { loadError = error.localizedDescription }
        loading = false
    }

    private func retry(_ item: ImportQueueItem) async {
        guard let token = appState.session?.sessionToken else { return }
        retryingIds.insert(item.id)
        defer { retryingIds.remove(item.id) }
        do {
            try await WhatsubAPI.shared.retryImport(id: item.id, token: token)
            await load()   // refresh: the item should now show 待处理
        } catch {
            loadError = error.localizedDescription
        }
    }
}
