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
                            }
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
    @State private var seekTo: Double? = nil

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
                // Shared player — created here ONCE per expanded card. Tap on
                // a phrase row below sets `seekTo`, PhrasePlayerView observes
                // it (Stage-2 binding) and seeks the AVPlayer in place.
                PhrasePlayerView(source: group.representativeSource, seekTo: seekTo)
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 4) {
                    ForEach(group.items) { item in
                        phraseRow(item)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 14))
    }

    private func phraseRow(_ item: MineItem) -> some View {
        let isActive = (seekTo != nil) && (seekTo == item.source.timestampSec)
        return Button {
            // nil → same timestamp doesn't trigger seek; toggling via small
            // dance ensures the binding fires even when re-tapping the same row.
            seekTo = nil
            DispatchQueue.main.async {
                seekTo = item.source.timestampSec
            }
        } label: {
            HStack(spacing: 10) {
                Text(item.source.timestampSec.map { mmss($0) } ?? "—:—")
                    .font(.caption.monospaced())
                    .foregroundStyle(isActive ? .whatsubAccent : .whatsubInkMuted)
                    .frame(width: 50, alignment: .leading)
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
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isActive ? Color.whatsubAccent.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .disabled(item.source.timestampSec == nil)
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
