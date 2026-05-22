import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryViewModel()

    var body: some View {
        NavigationStack {
            // Background as a `.background` MODIFIER (not a ZStack sibling layer)
            // + navigationDestination at the STABLE root (not inside a conditional
            // content branch). The old `ZStack { Color.ignoresSafeArea(); List }`
            // + destination-inside-List caused the large title to collapse ~1s
            // after popping back from a detail (nav-bar layout recomputed against
            // the full-bleed background). This structure keeps the title sticky.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.whatsubBg.ignoresSafeArea())
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.large)
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
        } else if let err = vm.errorMessage, vm.entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.whatsubInkMuted)
                Text(err).font(.callout).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
                Text("下拉重试").font(.footnote).foregroundStyle(.whatsubInkFaint)
            }.padding(32)
        } else if vm.entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle").font(.system(size: 48)).foregroundStyle(.whatsubAccent)
                Text("还没有同步的视频").font(.headline).foregroundStyle(.whatsubInk)
                Text("在桌面端 whatSub 的视频卡片上点 ☁️ 同步到云，\n这里下拉刷新就能看到").font(.footnote)
                    .foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
            }.padding(32)
        } else {
            List(vm.entries) { entry in
                NavigationLink(value: entry.id) {
                    LibraryRow(entry: entry)
                }
                .listRowBackground(Color.whatsubBgElev)
            }
            .scrollContentBackground(.hidden)
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
                Text(durationText).font(.caption).foregroundStyle(.whatsubInkMuted)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var durationText: String {
        guard let s = entry.durationSec else { return "" }
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
