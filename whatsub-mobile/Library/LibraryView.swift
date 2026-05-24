import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryViewModel()
    @State private var pendingDelete: LibraryListItem?

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
                Text("Library")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.whatsubInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        }
    }

    private func reload() async {
        guard let token = appState.session?.sessionToken else { return }
        await vm.load(token: token)
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.entries.isEmpty {
            ProgressView().tint(.whatsubAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = vm.errorMessage, vm.entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.whatsubInkMuted)
                Text(err).font(.callout).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
                Text("下拉重试").font(.footnote).foregroundStyle(.whatsubInkFaint)
            }.padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.entries.isEmpty {
            // Center the empty state in the area below the header (the parent VStack
            // is .leading/.top, so without this the placeholder hugs the top-left on iPad).
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle").font(.system(size: 48)).foregroundStyle(.whatsubAccent)
                Text("还没有同步的视频").font(.headline).foregroundStyle(.whatsubInk)
                Text("在桌面端 whatSub 的视频卡片上点 ☁️ 同步到云，\n这里下拉刷新就能看到").font(.footnote)
                    .foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
            }.padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(vm.entries) { entry in
                NavigationLink(value: entry.id) {
                    LibraryRow(entry: entry)
                }
                .listRowBackground(Color.whatsubBgElev)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingDelete = entry } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .confirmationDialog(
                "从云端删除「\(pendingDelete?.title ?? "")」？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let e = pendingDelete, let token = appState.session?.sessionToken {
                        Task { await vm.delete(e.id, token: token); pendingDelete = nil }
                    }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("将从云端移除该视频（含已上传的视频文件）。桌面端的本地副本保留，可重新同步。")
            }
        }
    }
}

private struct LibraryRow: View {
    let entry: LibraryListItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.thumbUrl.flatMap(URL.init)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    // i.ytimg.com is a Google CDN — unreachable in mainland China
                    // without a VPN (same constraint as the YouTube player embed).
                    // Show a play-icon placeholder instead of an empty box.
                    ZStack {
                        Color.whatsubBgSoft
                        Image(systemName: "play.rectangle.fill")
                            .font(.title3)
                            .foregroundStyle(.whatsubInkFaint)
                    }
                }
            }
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
    @ViewBuilder
    private var vpnBadge: some View {
        let selfHosted = entry.videoUrl != nil
        Text(selfHosted ? "免 VPN" : "需 VPN")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                (selfHosted ? Color.green : Color.whatsubInkMuted).opacity(0.22),
                in: Capsule()
            )
            .foregroundStyle(selfHosted ? Color.green : Color.whatsubInkMuted)
    }
}
