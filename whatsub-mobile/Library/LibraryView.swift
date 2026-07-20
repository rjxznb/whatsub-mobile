import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryViewModel()
    @State private var pendingDelete: LibraryListItem?
    /// 2026-06-05: 导入视频 moved here from 我的→工具 (more discoverable
    /// — new users hit it from the empty Library state). Sheet (not nav
    /// push) so it doesn't deepen the Library tab's navigation stack.
    @State private var showImport = false
    /// VPN split-routing guidance (2026-07-20). Two triggers: the load-error
    /// state when a VPN tunnel is detected (the VPN routed eversay.cc
    /// overseas → our API fails), and tapping a 需VPN badge on a row.
    @State private var showVPNHelp = false
    // Migrate-vocab-before-delete flow removed (build 248+) — the local
    // vocab notebook is retired; corpus phrases that referenced the deleted
    // video keep their data + can fall back to YT embed via source.youtubeId.

    var body: some View {
        NavigationStack {
            // Custom "Library" header instead of the system large title.
            // The system navigationTitle proved flaky here: with our global
            // black UINavigationBarAppearance + custom background + the
            // push/pop to detail, the large title intermittently collapsed
            // OR rendered invisible (space reserved, no text). A plain Text
            // header is 100% reliable + gives the exact top-left large-title
            // look. System nav bar is hidden on this screen; the detail view
            // shows its own bar (with back button) when pushed.
            VStack(alignment: .leading, spacing: 0) {
                // Header row: title left, "+" import button right. Same
                // baseline alignment so the "+" sits in the visual
                // shoulder of the large title.
                HStack(alignment: .firstTextBaseline) {
                    Text("Library")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.whatsubInk)
                    Spacer()
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.whatsubAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("导入视频")
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.whatsubBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                LibraryDetailView(entryId: id)
            }
            .task { if !vm.loadedOnce { await reload() } }
            .refreshable { await reload() }
            .sheet(isPresented: $showVPNHelp) {
                VPNRuleHelpSheet()
            }
            .sheet(isPresented: $showImport) {
                // ImportView expects to be inside a NavigationStack — it
                // uses .navigationTitle internally. Wrap so the sheet
                // gets a top bar with the "导入视频" title + close affordance.
                NavigationStack {
                    ImportView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showImport = false }
                            }
                        }
                }
                // Swipe-down-to-dismiss was triggering accidental close on
                // the idle/select page; explicit "关闭" button stays.
                .interactiveDismissDisabled()
            }
        }
    }

    private func reload() async {
        guard let session = appState.session else { return }
        await vm.load(token: session.sessionToken, email: session.email)
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.entries.isEmpty {
            ProgressView().tint(.whatsubAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = vm.errorMessage, vm.entries.isEmpty {
            // Wrap in ScrollView so .refreshable on the parent fires
            // pull-to-refresh — a bare VStack has no scrollable
            // container for the gesture to anchor to. Same trick the
            // empty state below uses.
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.whatsubInkMuted)
                    Text(err).font(.callout).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
                    // VPN-aware diagnosis (2026-07-20): when a tunnel is up
                    // and our API failed, the overwhelmingly likely cause is
                    // the VPN routing eversay.cc overseas. Name the cause +
                    // hand over the one-time fix instead of a mute "重试".
                    if VPNDetector.isVPNActive() {
                        VStack(spacing: 8) {
                            Text("检测到 VPN 开启 — 可能是它把 whatSub 的国内服务器也代理了")
                                .font(.footnote)
                                .foregroundStyle(.yellow)
                                .multilineTextAlignment(.center)
                            Button {
                                showVPNHelp = true
                            } label: {
                                Label("一次设置，免开关 VPN", systemImage: "network.badge.shield.half.filled")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.whatsubAccent)
                        }
                        .padding(.top, 4)
                    }
                    Text("下拉重试").font(.footnote).foregroundStyle(.whatsubInkFaint)
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: 400)
            }
        } else if vm.entries.isEmpty {
            // 2026-06-05: enriched empty state with the three import paths
            // (was previously a single line pointing only to the desktop
            // sync route). Surfaces:
            //   ① 「+」 toolbar (paste a YouTube / B 站 URL)
            //   ② Share extension (YouTube / B 站 → whatSub)
            //   ③ Desktop sync (cloud icon in the desktop client)
            // Only shown on empty Library — once the user has any video
            // here, the "+" button alone is enough discoverability; we
            // don't add a persistent footer to non-empty lists.
            // ScrollView wrap so .refreshable on the parent ENABLES
            // pull-to-refresh — bare VStack has no scrollable container
            // for the gesture to attach to (user-reported 2026-06-05:
            // "没有任何视频时下拉没有刷新事件"). minHeight forces the
            // ScrollView's content tall enough that the gesture is
            // actually available (pull-to-refresh needs SOME scrollable
            // space to bounce).
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.whatsubAccent)
                    Text("还没有视频")
                        .font(.headline)
                        .foregroundStyle(.whatsubInk)
                    VStack(alignment: .leading, spacing: 10) {
                        importHintRow(icon: "plus.circle.fill",
                                      text: "点击右上角「+」粘贴 YouTube、B 站等链接")
                        importHintRow(icon: "square.and.arrow.up",
                                      text: "在视频 app 里点分享 → whatSub")
                        importHintRow(icon: "icloud.and.arrow.down",
                                      text: "桌面端点 ☁️ 同步,这里下拉刷新")
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 12)
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: 400)
            }
        } else {
            List(vm.entries) { entry in
                NavigationLink(value: entry.id) {
                    LibraryRow(entry: entry, refreshNonce: vm.thumbRefreshNonce,
                               onNeedsVPNTap: { showVPNHelp = true })
                }
                .listRowBackground(Color.whatsubBgElev)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = entry
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            // .alert (centered modal) instead of .confirmationDialog — the latter
            // renders as a popover on iPad that anchored to the List, appearing far
            // from the swiped row.
            .alert(
                "从云端删除？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { entry in
                Button("删除", role: .destructive) {
                    if let token = appState.session?.sessionToken {
                        Task { await vm.delete(entry.id, token: token) }
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { entry in
                Text("「\(entry.title)」将从云端移除（含已上传的视频文件）。桌面端本地副本保留，可重新同步。")
            }
        }
    }

    /// One row in the empty-state import-paths block. The leading-icon
    /// width is fixed so the text lines up vertically across rows
    /// regardless of which SF Symbol gets used.
    private func importHintRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.whatsubAccent)
                .frame(width: 18, alignment: .center)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct LibraryRow: View {
    let entry: LibraryListItem
    /// Bumped by `LibraryViewModel.thumbRefreshNonce` on every reload —
    /// threaded into `RemoteImage` so pull-to-refresh also forces the
    /// thumbnail to re-fetch (bypassing URLCache + iOS DNS staleness
    /// after a VPN flip). See `Components/RemoteImage.swift`.
    let refreshNonce: Int
    /// Tap on the 需VPN badge → parent presents VPNRuleHelpSheet. Turns
    /// every "为什么这个要 VPN?" moment into the one-time-setup pitch.
    let onNeedsVPNTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: entry.thumbUrl.flatMap(URL.init),
                        refreshId: refreshNonce)
                .frame(width: 96, height: 54)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.subheadline).foregroundStyle(.whatsubInk).lineLimit(2)
                HStack(spacing: 8) {
                    Text(durationText).font(.caption).foregroundStyle(.whatsubInkMuted)
                    vpnBadge
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var durationText: String {
        guard let s = entry.durationSec else { return "" }
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Self-hosted (OSS, has videoUrl) → plays without VPN; else YouTube-embed → needs VPN.
    /// The 需VPN variant is TAPPABLE (2026-07-20) — opens the split-routing
    /// guide. `.borderless` so the badge captures its own touch instead of
    /// firing together with the row's NavigationLink (documented List-row
    /// multi-button gotcha).
    @ViewBuilder
    private var vpnBadge: some View {
        let selfHosted = entry.videoUrl != nil
        let label = Text(selfHosted ? "免 VPN" : "需 VPN")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                (selfHosted ? Color.green : Color.whatsubInkMuted).opacity(0.22),
                in: Capsule()
            )
            .foregroundStyle(selfHosted ? Color.green : Color.whatsubInkMuted)
        if selfHosted {
            label
        } else {
            Button(action: onNeedsVPNTap) {
                HStack(spacing: 2) {
                    label
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.whatsubInkFaint)
                }
            }
            .buttonStyle(.borderless)
        }
    }
}
