import SwiftUI

struct ImportQueueView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var items: [ImportQueueItem] = []
    @State private var managedJobs: [ManagedAnalysisJob] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var managedLoadError: String?
    @State private var retryingIds: Set<String> = []
    @State private var actingManagedIDs: Set<String> = []
    @State private var loadingManaged = false
    @State private var desktopSeenSecondsAgo: Int?

    private var showDesktopOfflineBanner: Bool {
        let waiting = items.contains { $0.status == "pending" || $0.status == "processing" }
        guard waiting else { return false }
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
                        Text("桌面端似乎不在线。打开电脑上的 whatSub 并登录同一账号后，桌面任务才会开始。")
                            .font(.footnote)
                            .foregroundStyle(.whatsubInk)
                    }
                    .listRowBackground(Color.yellow.opacity(0.12))
                }

                if !managedJobs.isEmpty {
                    Section("手机后台解析") {
                        ForEach(sortedManagedJobs) { job in
                            managedRow(job)
                                .listRowBackground(Color.whatsubBgElev)
                        }
                    }
                }

                if !items.isEmpty {
                    Section("桌面端导入") {
                        ForEach(sortedItems) { item in
                            desktopRow(item)
                                .listRowBackground(Color.whatsubBgElev)
                        }
                    }
                }

                if let loadError {
                    Text(loadError)
                        .foregroundStyle(.whatsubInkMuted)
                        .listRowBackground(Color.whatsubBgElev)
                }
                if let managedLoadError {
                    Text(managedLoadError)
                        .foregroundStyle(.whatsubInkMuted)
                        .listRowBackground(Color.whatsubBgElev)
                }
                if loadError == nil, managedLoadError == nil,
                   items.isEmpty, managedJobs.isEmpty, !loading {
                    Text("还没有导入或手机后台解析任务。")
                        .foregroundStyle(.whatsubInkMuted)
                        .listRowBackground(Color.whatsubBgElev)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await loadAll() }
        }
        .navigationTitle("导入队列")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await loadAll()
        }
        .task(id: managedPollingEnabled) {
            guard managedPollingEnabled else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard managedPollingEnabled else { return }
                await loadManagedJobs()
            }
        }
    }

    private var sortedItems: [ImportQueueItem] {
        items.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var sortedManagedJobs: [ManagedAnalysisJob] {
        managedJobs.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var managedPollingEnabled: Bool {
        scenePhase == .active
            && managedJobs.contains { $0.status == .queued || $0.status == .running }
    }

    @ViewBuilder
    private func managedRow(_ job: ManagedAnalysisJob) -> some View {
        let presentation = job.presentation
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("手机解析任务", systemImage: "iphone")
                    .font(.subheadline)
                    .foregroundStyle(.whatsubInk)
                Spacer()
                Text(job.tier == .pro ? "Pro" : "体验")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.whatsubAccent)
            }
            Text(presentation.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(managedStatusColor(job.status))
            if job.status == .running || job.status == .queued {
                ProgressView(value: job.progress)
                    .tint(.whatsubAccent)
            }
            if let detail = presentation.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
            }
            HStack {
                if presentation.canResume {
                    Button("继续") { Task { await resume(job) } }
                        .buttonStyle(.bordered)
                        .tint(.whatsubAccent)
                }
                if presentation.canCancel {
                    Button("取消", role: .destructive) { Task { await cancel(job) } }
                        .buttonStyle(.bordered)
                }
                if let entryID = presentation.entryID {
                    Button("打开视频") { openLibraryEntry(entryID) }
                        .buttonStyle(.borderedProminent)
                        .tint(.whatsubAccent)
                }
                if actingManagedIDs.contains(job.id) {
                    ProgressView().tint(.whatsubAccent)
                }
            }
            .disabled(actingManagedIDs.contains(job.id))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func desktopRow(_ item: ImportQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.url)
                .font(.subheadline)
                .foregroundStyle(.whatsubInk)
                .lineLimit(1)
            HStack(spacing: 8) {
                desktopStatusChip(item.status)
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
            if item.status == "failed", let error = item.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.whatsubInkMuted)
            }
        }
        .padding(.vertical, 4)
    }

    private func managedStatusColor(_ status: ManagedAnalysisJobStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed, .cancelled: return .whatsubHighlight
        case .pausedQuota: return .yellow
        case .queued, .running: return .whatsubAccent
        }
    }

    @ViewBuilder
    private func desktopStatusChip(_ status: String) -> some View {
        let value: (String, Color) = {
            switch status {
            case "pending": return ("待处理", .whatsubInkMuted)
            case "processing": return ("处理中", .whatsubAccent)
            case "done": return ("已完成", .green)
            case "failed": return ("失败", .whatsubHighlight)
            default: return (status, .whatsubInkMuted)
            }
        }()
        Text(value.0)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(value.1.opacity(0.15), in: Capsule())
            .foregroundStyle(value.1)
    }

    private func loadAll() async {
        guard let token = appState.session?.sessionToken else {
            loadError = "请先登录"
            return
        }
        loading = true
        loadError = nil
        do {
            let response = try await WhatsubAPI.shared.listImportQueue(token: token)
            items = response.items
            desktopSeenSecondsAgo = response.desktopSeenSecondsAgo
        } catch {
            loadError = error.localizedDescription
        }
        await loadManagedJobs()
        loading = false
    }

    private func loadManagedJobs() async {
        guard let token = appState.session?.sessionToken else { return }
        guard !loadingManaged else { return }
        loadingManaged = true
        defer { loadingManaged = false }
        do {
            managedJobs = try await WhatsubAPI.shared.jobs(token: token)
            managedLoadError = nil
        } catch {
            managedLoadError = error.localizedDescription
        }
    }

    private func retry(_ item: ImportQueueItem) async {
        guard let token = appState.session?.sessionToken else { return }
        retryingIds.insert(item.id)
        defer { retryingIds.remove(item.id) }
        do {
            try await WhatsubAPI.shared.retryImport(id: item.id, token: token)
            await loadAll()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func cancel(_ job: ManagedAnalysisJob) async {
        guard let token = appState.session?.sessionToken else { return }
        actingManagedIDs.insert(job.id)
        defer { actingManagedIDs.remove(job.id) }
        do {
            replaceManagedJob(try await WhatsubAPI.shared.cancel(id: job.id, token: token))
        } catch {
            managedLoadError = error.localizedDescription
        }
    }

    private func resume(_ job: ManagedAnalysisJob) async {
        guard let token = appState.session?.sessionToken else { return }
        actingManagedIDs.insert(job.id)
        defer { actingManagedIDs.remove(job.id) }
        do {
            replaceManagedJob(try await WhatsubAPI.shared.resume(id: job.id, token: token))
        } catch {
            managedLoadError = error.localizedDescription
        }
    }

    private func replaceManagedJob(_ updated: ManagedAnalysisJob) {
        if let index = managedJobs.firstIndex(where: { $0.id == updated.id }) {
            managedJobs[index] = updated
        } else {
            managedJobs.append(updated)
        }
    }

    private func openLibraryEntry(_ id: String) {
        appState.pendingLibraryEntryID = id
        appState.selectedTab = 0
    }
}
