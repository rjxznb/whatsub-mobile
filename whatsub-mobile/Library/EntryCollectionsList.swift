import SwiftUI

/// Stage 5 of the 2026-06-03 corpus refactor. Inside the Library video detail
/// page, gives the user "这个视频的收藏" — every personal corpus phrase tagged
/// with this Library entry id, listed in cue order with seekable rows.
///
/// Tapping a row calls `onTapPhrase(seconds)` so the parent's existing
/// SeekRequest pipeline drives the AVPlayer; no second player here.
struct EntryCollectionsList: View {
    let entryId: String
    /// Called when the user taps a phrase row → parent seeks its main player.
    let onTapPhrase: (Double) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case ready([MineItem])
        case error(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack {
                    Spacer()
                    ProgressView().tint(.whatsubAccent)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .error(let msg):
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.whatsubInkMuted)
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkMuted)
                    Button("重试") { Task { await reload() } }
                        .font(.footnote)
                        .foregroundStyle(.whatsubAccent)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready(let items):
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "bookmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.whatsubAccent)
                        Text("这个视频还没收藏")
                            .font(.headline)
                            .foregroundStyle(.whatsubInk)
                        Text("在字幕里长按一句话 → 选词加入语料库\n这里就会出现")
                            .font(.footnote)
                            .foregroundStyle(.whatsubInkMuted)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { item in
                                phraseRow(item)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .task(id: entryId) { await reload() }
    }

    private func phraseRow(_ item: MineItem) -> some View {
        // Geometry mirrors CueRow (字幕卡 above) — same font sizes, paddings,
        // corner radius — so the 收藏 tab feels like a continuation of the
        // subtitle reading surface rather than a denser secondary list.
        // Timestamp moved to top-left of the card (a small label above the
        // phrase) instead of a 50pt-wide left gutter, so the phrase body
        // gets the full content width.
        Button {
            if let ts = item.source.timestampSec {
                onTapPhrase(ts)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let ts = item.source.timestampSec {
                    Text(mmss(ts))
                        .font(.caption.monospaced())
                        .foregroundStyle(.whatsubAccent)
                }
                Text(item.phraseRaw)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.whatsubInk)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let m = item.meaningZh, !m.isEmpty {
                    Text(m)
                        .font(.system(size: 16))
                        .foregroundStyle(.whatsubInkMuted)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(item.source.timestampSec == nil)
    }

    private func mmss(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }

    @MainActor
    private func reload() async {
        guard let token = appState.session?.sessionToken else {
            phase = .error("请先登录")
            return
        }
        phase = .loading
        do {
            let resp = try await WhatsubAPI.shared.mineCorpus(tags: [], token: token)
            let filtered = resp.items
                .filter { $0.source.libraryEntryId == entryId }
                .sorted { lhs, rhs in
                    let lt = lhs.source.timestampSec ?? .greatestFiniteMagnitude
                    let rt = rhs.source.timestampSec ?? .greatestFiniteMagnitude
                    if lt != rt { return lt < rt }
                    return lhs.contributedAt < rhs.contributedAt
                }
            phase = .ready(filtered)
        } catch let e as APIError {
            phase = .error(e.chinese)
        } catch {
            phase = .error("加载失败：\(error.localizedDescription)")
        }
    }
}
