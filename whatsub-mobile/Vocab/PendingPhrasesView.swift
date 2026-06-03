import SwiftUI

/// Reviews + syncs the local pending-phrase queue. Two presentation modes:
///
/// - `filterEntryId: nil`  → "全部待同步" — shown in the Me-tab Tools entry,
///   lists every video's pending phrases grouped by video.
/// - `filterEntryId: "abc"` → shown from a Library detail page's banner;
///   pre-filtered to one bucket so the user can sync just THAT video's
///   collection without scrolling through the rest.
///
/// Multi-select with a checkmark column; bottom safe-area inset shows the
/// "同步选中的 N 条" button. Sync sequentially loops the existing
/// /api/corpus/contribute endpoint (no new backend) — succeeded items leave
/// the store, failed items stay (with their error inline) so a partial
/// failure leaves the work where the user can retry.
struct PendingPhrasesView: View {
    let filterEntryId: String?

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PendingPhraseStore.shared

    @State private var selected: Set<UUID> = []
    @State private var syncing: Bool = false
    @State private var syncProgress: String? = nil           // "正在同步 3/12…"
    @State private var perItemError: [UUID: String] = [:]    // shows under failing rows
    @State private var topBanner: BannerKind? = nil           // success / quota / network

    enum BannerKind: Equatable {
        case info(String)
        case quotaHit(String)   // 413 from server — show with subscribe nudge
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color.whatsubBg.ignoresSafeArea())
                .navigationTitle(filterEntryId == nil ? "待同步暂存" : "本视频待同步")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }.disabled(syncing)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(allVisibleSelected ? "取消全选" : "全选") {
                            toggleSelectAll()
                        }
                        .disabled(visibleItems.isEmpty || syncing)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !visibleItems.isEmpty {
                        bottomBar
                            .background(Color.whatsubBg)
                    }
                }
        }
    }

    // MARK: - main content (groups + rows / empty / banners)

    @ViewBuilder
    private var content: some View {
        if visibleGroups.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let banner = topBanner {
                        bannerView(banner)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    ForEach(visibleGroups) { g in
                        groupCard(g)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.whatsubAccent)
            Text(filterEntryId == nil ? "暂存区是空的" : "这个视频还没有待同步的短语")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
            Text("在 Library 字幕长按一句话 → 加入暂存\n后再来这里挑哪些同步到云端语料库")
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - one group (video bucket)

    @ViewBuilder
    private func groupCard(_ g: PendingGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Group header: video title + bucket count + per-group toggle
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "tv")
                    .foregroundStyle(.whatsubAccent)
                Text(g.videoTitle.isEmpty ? "未命名视频" : g.videoTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text("\(g.items.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.whatsubInkMuted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.whatsubBg.opacity(0.6), in: Capsule())
            }

            VStack(spacing: 4) {
                ForEach(g.items) { item in
                    phraseRow(item)
                }
            }
        }
        .padding(14)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    private func phraseRow(_ item: PendingPhrase) -> some View {
        Button {
            if selected.contains(item.id) { selected.remove(item.id) }
            else { selected.insert(item.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected.contains(item.id) ? Color.whatsubAccent : Color.whatsubInkFaint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mmss(item.timestampSec))
                            .font(.caption.monospaced())
                            .foregroundStyle(.whatsubInkMuted)
                            .frame(width: 50, alignment: .leading)
                        Text(item.phraseRaw)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.whatsubInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let m = item.meaningZh, !m.isEmpty {
                        Text(m)
                            .font(.caption)
                            .foregroundStyle(.whatsubInkMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let err = perItemError[item.id] {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(err)
                                .foregroundStyle(.whatsubInkMuted)
                        }
                        .font(.caption2)
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(
                selected.contains(item.id) ? Color.whatsubAccent.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .disabled(syncing)
    }

    // MARK: - bottom bar (sync button + progress)

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let progress = syncProgress {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
            }
            Button {
                Task { await syncSelected() }
            } label: {
                HStack(spacing: 8) {
                    if syncing { ProgressView().tint(.white) }
                    else { Image(systemName: "icloud.and.arrow.up.fill") }
                    Text(syncing
                         ? "同步中…"
                         : "同步选中的 \(selected.count) 条")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(selected.isEmpty ? Color.whatsubInkFaint : Color.whatsubAccent,
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .disabled(selected.isEmpty || syncing)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: BannerKind) -> some View {
        switch banner {
        case .info(let msg):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(msg).font(.footnote).foregroundStyle(.whatsubInk)
                Spacer()
                Button { topBanner = nil } label: {
                    Image(systemName: "xmark").font(.caption).foregroundStyle(.whatsubInkMuted)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 10))

        case .quotaHit(let msg):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(msg).font(.footnote).foregroundStyle(.whatsubInk)
                    Spacer()
                    Button { topBanner = nil } label: {
                        Image(systemName: "xmark").font(.caption).foregroundStyle(.whatsubInkMuted)
                    }
                }
                Text("订阅 Pro 后语料库上限 → 1000 条")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - derived data

    private var visibleGroups: [PendingGroup] {
        if let id = filterEntryId {
            return store.byVideo.filter { $0.entryId == id }
        }
        return store.byVideo
    }

    private var visibleItems: [PendingPhrase] { visibleGroups.flatMap(\.items) }

    private var allVisibleSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { selected.contains($0.id) }
    }

    private func toggleSelectAll() {
        if allVisibleSelected {
            visibleItems.forEach { selected.remove($0.id) }
        } else {
            visibleItems.forEach { selected.insert($0.id) }
        }
    }

    // MARK: - sync

    /// Sequentially POST each selected phrase. Succeeded ids leave the store
    /// at the end (one save() instead of N for less disk thrash). Failures
    /// stay in the store with their error inline; quota (413) stops the
    /// batch since every following call would also 413.
    private func syncSelected() async {
        guard let token = appState.session?.sessionToken else {
            topBanner = .info("请先到「我的」登录后再同步")
            return
        }
        let pool = visibleItems.filter { selected.contains($0.id) }
        guard !pool.isEmpty else { return }

        syncing = true
        perItemError.removeAll()
        topBanner = nil
        var succeededIds: Set<UUID> = []
        var failedCount = 0

        for (i, p) in pool.enumerated() {
            syncProgress = "正在同步 \(i + 1)/\(pool.count)…"
            let source: PhraseSource = .library(
                entryId: p.entryId,
                videoTitle: p.videoTitle,
                youtubeId: p.youtubeId,
                timestampSec: p.timestampSec
            )
            do {
                _ = try await WhatsubAPI.shared.contributePhrase(
                    phraseRaw: p.phraseRaw,
                    contextSentence: p.contextSentence,
                    source: source,
                    meaningZh: p.meaningZh,
                    usageNote: p.usageNote,
                    tags: [],
                    token: token
                )
                succeededIds.insert(p.id)
            } catch let e as APIError {
                failedCount += 1
                perItemError[p.id] = e.chinese
                if case .server(let code, _) = e, code == 413 {
                    // Quota exhausted — pointless to keep trying.
                    topBanner = .quotaHit(e.chinese)
                    break
                }
            } catch {
                failedCount += 1
                perItemError[p.id] = "同步失败：\(error.localizedDescription)"
            }
        }

        store.remove(ids: succeededIds)
        selected.subtract(succeededIds)
        syncing = false
        syncProgress = nil

        if !succeededIds.isEmpty, topBanner == nil {
            let msg: String
            if failedCount > 0 {
                msg = "成功同步 \(succeededIds.count) 条，\(failedCount) 条失败（详见下方）"
            } else {
                msg = "成功同步 \(succeededIds.count) 条到云端语料库"
            }
            topBanner = .info(msg)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if !succeededIds.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if failedCount > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func mmss(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }
}
