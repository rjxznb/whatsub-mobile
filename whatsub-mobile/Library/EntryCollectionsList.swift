import SwiftUI

/// Stage 5 of the 2026-06-03 corpus refactor. Inside the Library video detail
/// page, gives the user "这个视频的收藏" — every phrase tied to this Library
/// entry, listed in cue order with seekable rows.
///
/// As of 2026-06-07 this tab is the SOLE surface for pending phrases too
/// (was: a banner above + a separate global view in 我的). Rows are
/// merged:
///   - pending (local, `PendingPhraseStore`) — has a ☁️ upload button
///     on the right; tap it to POST the phrase to the cloud corpus and
///     remove it from the local store on success.
///   - synced (cloud, `mineCorpus` filtered by entryId) — no upload
///     button; already in the cloud.
/// Sorted together by timestamp so the user reads them in video order
/// regardless of sync state.
///
/// Tapping a row body calls `onTapPhrase(seconds)` so the parent's
/// existing SeekRequest pipeline drives the AVPlayer; no second player
/// here.
struct EntryCollectionsList: View {
    let entryId: String
    /// Library entry's YouTube id (when available) — needed to build the
    /// PhraseSource if the user uploads a pending phrase that didn't
    /// remember it at collect time.
    let youtubeId: String?
    /// Called when the user taps a phrase row → parent seeks its main player.
    let onTapPhrase: (Double) -> Void

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var pendingStore = PendingPhraseStore.shared

    @State private var syncedItems: [MineItem] = []
    @State private var phase: Phase = .loading
    /// Per-row in-flight upload — keys are PendingPhrase.id so multiple
    /// uploads can be tracked simultaneously without blocking other rows.
    @State private var uploadingIds: Set<UUID> = []
    /// Per-row upload error — surfaces inline next to the row instead of
    /// a popup so the user can still read context.
    @State private var uploadErrors: [UUID: String] = [:]

    enum Phase {
        case loading
        case ready
        case error(String)
    }

    /// Merged + sorted rows. Pending phrases come from PendingPhraseStore
    /// (filtered to this entry); synced phrases come from the cached
    /// syncedItems we loaded via `reload`. Stable sort by timestamp.
    private var rows: [Row] {
        let pendingRows = pendingStore.items
            .filter { $0.entryId == entryId }
            .map(Row.pending)
        let syncedRows = syncedItems.map(Row.synced)
        return (pendingRows + syncedRows).sorted { lhs, rhs in
            let lt = lhs.timestampSec ?? .greatestFiniteMagnitude
            let rt = rhs.timestampSec ?? .greatestFiniteMagnitude
            if lt != rt { return lt < rt }
            return lhs.collectedAt < rhs.collectedAt
        }
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

            case .ready:
                if rows.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(rows) { row in
                                phraseRow(row)
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bookmark")
                .font(.system(size: 36))
                .foregroundStyle(.whatsubAccent)
            Text("这个视频还没收藏")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
            Text("在字幕里长按一句话 → 选词加入收藏\n这里就会出现")
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func phraseRow(_ row: Row) -> some View {
        // Geometry mirrors CueRow (字幕卡 above) — same font sizes, paddings,
        // corner radius — so the 收藏 tab feels like a continuation of the
        // subtitle reading surface rather than a denser secondary list.
        HStack(alignment: .top, spacing: 10) {
            Button {
                if let ts = row.timestampSec { onTapPhrase(ts) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if let ts = row.timestampSec {
                        Text(mmss(ts))
                            .font(.caption.monospaced())
                            .foregroundStyle(.whatsubAccent)
                    }
                    Text(row.phraseRaw)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.whatsubInk)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let m = row.meaningZh, !m.isEmpty {
                        Text(m)
                            .font(.system(size: 16))
                            .foregroundStyle(.whatsubInkMuted)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case let .pending(p) = row,
                       let err = uploadErrors[p.id], !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(row.timestampSec == nil)

            uploadButton(for: row)
        }
    }

    /// ☁️ on the right of a pending row → uploads to cloud corpus and
    /// removes from the local store on success. Synced rows render an
    /// invisible spacer of the same width so the row body sizing stays
    /// consistent.
    @ViewBuilder
    private func uploadButton(for row: Row) -> some View {
        switch row {
        case .pending(let pending):
            let inFlight = uploadingIds.contains(pending.id)
            Button {
                Task { await upload(pending) }
            } label: {
                if inFlight {
                    ProgressView()
                        .tint(.whatsubAccent)
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.whatsubAccent)
                        .frame(width: 36, height: 36)
                        .background(Color.whatsubBgElev, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .disabled(inFlight)
            .padding(.top, 4)

        case .synced:
            // Equal-width invisible slot so synced + pending rows align.
            Color.clear.frame(width: 36, height: 36)
        }
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
            syncedItems = resp.items
                .filter { $0.source.libraryEntryId == entryId }
            phase = .ready
        } catch let e as APIError {
            phase = .error(e.chinese)
        } catch {
            phase = .error("加载失败：\(error.localizedDescription)")
        }
    }

    /// Push a single pending phrase to the cloud corpus.
    /// - Success: remove from PendingPhraseStore + add the returned
    ///   contributionId-backed item to syncedItems (so the UI moves the row
    ///   from "pending visual" to "synced visual" without a full reload).
    /// - Failure: write to uploadErrors so the row shows it inline.
    @MainActor
    private func upload(_ pending: PendingPhrase) async {
        guard let token = appState.session?.sessionToken else { return }
        uploadErrors[pending.id] = nil
        uploadingIds.insert(pending.id)
        defer { uploadingIds.remove(pending.id) }

        let source = PhraseSource.library(
            entryId: pending.entryId,
            videoTitle: pending.videoTitle,
            youtubeId: pending.youtubeId ?? youtubeId,
            timestampSec: pending.timestampSec
        )
        do {
            _ = try await WhatsubAPI.shared.contributePhrase(
                phraseRaw: pending.phraseRaw,
                contextSentence: pending.contextSentence,
                source: source,
                meaningZh: pending.meaningZh,
                usageNote: pending.usageNote,
                tags: [],
                token: token
            )
            pendingStore.remove(ids: [pending.id])
            // Re-pull synced list from server so the canonical
            // CorpusSource-shaped row replaces the pending visual. Local
            // synthesis would have to construct a CorpusSource +
            // phraseNormalized that match server-side normalisation —
            // not worth the duplication for what's typically a sub-second
            // round-trip.
            await reload()
        } catch let e as APIError {
            uploadErrors[pending.id] = e.chinese
        } catch {
            uploadErrors[pending.id] = "上传失败：\(error.localizedDescription)"
        }
    }

    /// Unified row payload — pending (local) or synced (cloud). The render
    /// path branches on the case for the right-rail button + meta only;
    /// the body text is the same for both.
    enum Row: Identifiable {
        case pending(PendingPhrase)
        case synced(MineItem)

        var id: String {
            switch self {
            case .pending(let p): return "p-\(p.id.uuidString)"
            case .synced(let m): return "s-\(m.contributionId.map(String.init) ?? UUID().uuidString)"
            }
        }
        var timestampSec: Double? {
            switch self {
            case .pending(let p): return p.timestampSec
            case .synced(let m): return m.source.timestampSec
            }
        }
        var phraseRaw: String {
            switch self {
            case .pending(let p): return p.phraseRaw
            case .synced(let m): return m.phraseRaw
            }
        }
        var meaningZh: String? {
            switch self {
            case .pending(let p): return p.meaningZh
            case .synced(let m): return m.meaningZh
            }
        }
        /// Stable-sort tiebreaker within the same timestamp bucket.
        /// MineItem.contributedAt is epoch milliseconds (Int64); convert
        /// to seconds-as-Double so it lives on the same scale as
        /// PendingPhrase.collectedAt (already epoch seconds Double).
        var collectedAt: Double {
            switch self {
            case .pending(let p): return p.collectedAt
            case .synced(let m): return Double(m.contributedAt) / 1000.0
            }
        }
    }
}
