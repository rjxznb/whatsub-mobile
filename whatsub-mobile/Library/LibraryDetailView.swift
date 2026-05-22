import SwiftUI

struct LibraryDetailView: View {
    let entryId: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryDetailViewModel()
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            if vm.loading {
                ProgressView().tint(.whatsubAccent)
            } else if let err = vm.errorMessage {
                Text(err).foregroundStyle(.whatsubInkMuted).padding()
            } else if let entry = vm.entry {
                if vSize == .compact {
                    landscape(entry)
                } else {
                    portrait(entry)
                }
            }
        }
        .navigationTitle(vm.entry?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let token = appState.session?.sessionToken else { return }
            await vm.load(id: entryId, token: token)
        }
        .overlay { if vm.showPopup { highlightPopup } }
    }

    private func player(_ entry: LibraryEntryDetail) -> some View {
        YouTubeEmbedView(videoId: entry.youtubeId, seek: vm.seek) { sec in
            vm.onPlayerTime(sec)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private func portrait(_ entry: LibraryEntryDetail) -> some View {
        VStack(spacing: 0) {
            player(entry)
            subtitleList(entry)
        }
    }

    private func landscape(_ entry: LibraryEntryDetail) -> some View {
        ZStack(alignment: .bottom) {
            player(entry)
            subtitleList(entry)
                .frame(maxHeight: 180)
                .background(.black.opacity(0.55))
        }
    }

    private func subtitleList(_ entry: LibraryEntryDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entry.analysisJson.subtitles) { cue in
                        CueRow(
                            cue: cue,
                            isCurrent: cue.index == vm.currentIndex,
                            onTapCue: { vm.seekTo(cue) },
                            onTapHighlight: { w, n, t in vm.showHighlight(word: w, note: n, translation: t) }
                        )
                        .id(cue.index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .onChange(of: vm.currentIndex) { idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    private var highlightPopup: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { vm.showPopup = false }
            VStack(alignment: .leading, spacing: 10) {
                Text(vm.popupWord ?? "").font(.title3.weight(.semibold)).foregroundStyle(.whatsubHighlight)
                if let t = vm.popupTranslation, !t.isEmpty {
                    Text(t).font(.body).foregroundStyle(.whatsubInk)
                }
                if let n = vm.popupNote, !n.isEmpty {
                    Text(n).font(.callout).foregroundStyle(.whatsubInkSoft)
                }
                Button("关闭") { vm.showPopup = false }
                    .font(.footnote).foregroundStyle(.whatsubAccent).padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: 320, alignment: .leading)
            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 16))
            .padding(40)
        }
    }
}
