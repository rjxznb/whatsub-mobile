import SwiftUI

struct ImportQueueView: View {
    @EnvironmentObject var appState: AppState
    @State private var items: [ImportQueueItem] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var retryingIds: Set<String> = []
    /// Seconds since the backend last saw this account's desktop client
    /// touch the queue. nil = never. Drives the offline banner below.
    @State private var desktopSeenSecondsAgo: Int?

    /// Show the banner only when it's actionable: there ARE queued tasks
    /// waiting AND the desktop hasn't polled within 4 cycles (30s × 4).
    private var showDesktopOfflineBanner: Bool {
        let hasWaiting = items.contains { $0.status == "pending" || $0.status == "processing" }
        guard hasWaiting else { return false }
        guard let ago = desktopSeenSecondsAgo else { return true }
        return ago > 120
    }

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            List {
                if showDesktopOfflineBanner {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("桌面端似乎不在线 — 打开电脑上的 whatSub 并登录同一账号后，排队任务才会开始处理。")
                            .font(.footnote)
                            .foregroundStyle(.whatsubInk)
                    }
                    .listRowBackground(Color.yellow.opacity(0.12))
                }
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
            if item.status == "pending" {
                Text("等待桌面端处理（桌面离线时排队，上线后自动处理）")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
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
        do {
            let resp = try await WhatsubAPI.shared.listImportQueue(token: token)
            items = resp.items
            desktopSeenSecondsAgo = resp.desktopSeenSecondsAgo
        } catch { loadError = error.localizedDescription }
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
