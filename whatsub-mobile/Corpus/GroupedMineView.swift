import SwiftUI

/// "By video" layout for the personal corpus (Stage 4 of the 2026-06-03
/// refactor). Groups MineItems by source (Library entry id → YouTube id →
/// URL → "manual") and renders each group as a collapsible card.
///
/// Expanded card layout:
///
///   [icon] Video title                              ▲
///          12 个收藏
///   ┌──────────────────────────────────────┐
///   │       (shared PhrasePlayerView)        │
///   └──────────────────────────────────────┘
///     0:42  figure it out
///     1:23  under the hood          ← tap → player seeks to 1:23
///     2:11  come to terms with
///
/// Performance: only ONE expanded card at a time (parent owns the expanded
/// id), so only one PhrasePlayerView (and one backend round-trip to resolve
/// the OSS videoUrl) is in flight at any moment. Tap a phrase row to seek.
struct GroupedMineView: View {
    let items: [MineItem]
    /// Tapped via long-press → Delete in the row context menu. Parent
    /// (CorpusView) handles the actual deletion + confirmation alert so
    /// the alert anchor stays at the tab-level safe area, not inside the
    /// scroll view (which would clip on iPad).
    var onDelete: ((MineItem) -> Void)? = nil

    @State private var expandedGroupId: String? = nil

    struct Group: Identifiable {
        let id: String                          // dedup key
        let title: String
        let kind: String
        let representativeSource: CorpusSource  // first item's source; player uses this
        let items: [MineItem]
    }

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 44))
                    .foregroundStyle(.whatsubAccent)
                Text("还没有按来源分组的短语")
                    .font(.headline)
                    .foregroundStyle(.whatsubInk)
                Text("先去 Library 里某个视频字幕长按收藏\n这里就会按视频归类").font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(groups) { g in
                        GroupCard(
                            group: g,
                            isExpanded: expandedGroupId == g.id,
                            onToggle: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    expandedGroupId = expandedGroupId == g.id ? nil : g.id
                                }
                            },
                            onDelete: onDelete
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    // ---- grouping ----

    private var groups: [Group] {
        var bucket: [String: [MineItem]] = [:]
        var order: [String] = []
        for m in items {
            let key = Self.groupKey(m.source)
            if bucket[key] == nil { order.append(key) }
            bucket[key, default: []].append(m)
        }
        return order.compactMap { key in
            guard let entries = bucket[key], let first = entries.first else { return nil }
            // Items within a group sorted by timestampSec (then contributedAt)
            // so the user scrubs through in video-watching order rather than
            // collection order.
            let sortedEntries = entries.sorted { lhs, rhs in
                let lt = lhs.source.timestampSec ?? .greatestFiniteMagnitude
                let rt = rhs.source.timestampSec ?? .greatestFiniteMagnitude
                if lt != rt { return lt < rt }
                return lhs.contributedAt < rhs.contributedAt
            }
            return Group(
                id: key,
                title: Self.displayTitle(for: first.source, key: key),
                kind: first.source.kind,
                representativeSource: first.source,
                items: sortedEntries
            )
        }
    }

    private static func groupKey(_ s: CorpusSource) -> String {
        if let id = s.libraryEntryId, !id.isEmpty { return "lib:\(id)" }
        if let id = s.youtubeId, !id.isEmpty       { return "yt:\(id)" }
        if let u = s.url, !u.isEmpty                { return "url:\(u)" }
        return "other:\(s.kind)"
    }

    private static func displayTitle(for source: CorpusSource, key: String) -> String {
        if let t = source.title, !t.isEmpty { return t }
        if key.hasPrefix("lib:") { return "Library 视频" }
        if key.hasPrefix("yt:")  { return "YouTube 视频" }
        if key.hasPrefix("url:") { return source.url ?? "未知来源" }
        switch source.kind {
        case "webpage": return "网页收藏"
        case "manual":  return "手动添加"
        default:        return "其他来源"
        }
    }
}

// ---- One group card ----

private struct GroupCard: View {
    let group: GroupedMineView.Group
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: ((MineItem) -> Void)?
    @State private var seekTo: Double? = nil
    @State private var safariURL: URL? = nil

    /// True for source kinds that have a playable video. Other kinds
    /// (webpage / pdf / manual) show a "打开来源" link instead of a player
    /// (build 247 showed "非视频来源" placeholder which was useless).
    private var hasPlayer: Bool {
        group.kind == "library" || group.kind == "youtube"
    }

    /// Best-effort URL for "打开来源" on non-video groups.
    private var sourceURL: URL? {
        if let u = group.representativeSource.url,
           let url = URL(string: u) { return url }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: iconForKind(group.kind))
                        .font(.title3)
                        .foregroundStyle(.whatsubAccent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.whatsubInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(group.items.count) 个收藏")
                            .font(.caption)
                            .foregroundStyle(.whatsubInkMuted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.whatsubInkMuted)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                if hasPlayer {
                    // Shared player — created here ONCE per expanded card.
                    // Tap on a phrase row below sets `seekTo`, PhrasePlayerView
                    // observes it (Stage-2 binding) and seeks the AVPlayer in place.
                    PhrasePlayerView(source: group.representativeSource, seekTo: seekTo)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let url = sourceURL {
                    // Non-video group (webpage / pdf / manual) → quick "打开来源"
                    // affordance in place of the fake player. Tapping opens
                    // Safari with the original page.
                    Button {
                        safariURL = url
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "safari")
                            Text("打开来源页面")
                                .font(.footnote.weight(.semibold))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.whatsubBg.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.whatsubAccent)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 4) {
                    ForEach(group.items) { item in
                        phraseRow(item)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 14))
        .sheet(item: Binding(
            get: { safariURL.map(IdentifiedURL.init) },
            set: { safariURL = $0?.url }
        )) { wrapper in
            SafariView(url: wrapper.url)
        }
    }

    private struct IdentifiedURL: Identifiable {
        var id: String { url.absoluteString }
        let url: URL
    }

    @ViewBuilder
    private func phraseRow(_ item: MineItem) -> some View {
        // Two shapes:
        //   playable (library/youtube + has timestamp): tap → seek
        //   informational (anything else): plain row, no tap action
        // Both share a contextMenu for delete (LazyVStack doesn't support
        // .swipeActions — only List does — so we use long-press menu instead).
        Group {
            if hasPlayer, let ts = item.source.timestampSec {
                let isActive = (seekTo != nil) && (seekTo == ts)
                Button {
                    // nil → same timestamp doesn't trigger seek; toggling via a
                    // small dance ensures the binding fires even when re-tapping
                    // the same row.
                    seekTo = nil
                    DispatchQueue.main.async { seekTo = ts }
                } label: {
                    HStack(spacing: 10) {
                        Text(mmss(ts))
                            .font(.caption.monospaced())
                            .foregroundStyle(isActive ? .whatsubAccent : .whatsubInkMuted)
                            .frame(width: 50, alignment: .leading)
                        phraseBody(item)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        isActive ? Color.whatsubAccent.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.whatsubInkFaint)
                        .frame(width: 50, alignment: .leading)
                    phraseBody(item)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .contextMenu {
            if let onDelete {
                Button(role: .destructive) {
                    onDelete(item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private func phraseBody(_ item: MineItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.phraseRaw)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.whatsubInk)
                .lineLimit(1)
            if let m = item.meaningZh, !m.isEmpty {
                Text(m)
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
                    .lineLimit(1)
            }
        }
    }

    private func iconForKind(_ kind: String) -> String {
        switch kind {
        case "library": return "tv"
        case "youtube": return "play.rectangle.fill"
        case "webpage": return "safari"
        default:        return "doc.text"
        }
    }

    private func mmss(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }
}
