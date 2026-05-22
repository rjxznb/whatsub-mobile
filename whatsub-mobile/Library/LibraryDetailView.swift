import SwiftUI

struct LibraryDetailView: View {
    let entryId: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryDetailViewModel()
    @Environment(\.verticalSizeClass) private var vSize
    @State private var playerReady = false
    @State private var playerTimedOut = false
    @State private var showCaptions = true

    private var isLandscape: Bool { vSize == .compact }

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            if vm.loading {
                ProgressView().tint(.whatsubAccent)
            } else if let err = vm.errorMessage {
                Text(err).foregroundStyle(.whatsubInkMuted).padding()
            } else if let entry = vm.entry {
                if isLandscape {
                    landscape(entry)
                } else {
                    portrait(entry)
                }
            }
        }
        .navigationTitle(vm.entry?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        // Landscape = fullscreen: hide the nav bar + status bar; portrait restores them.
        .toolbar(isLandscape ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(isLandscape)
        .task {
            guard let token = appState.session?.sessionToken else { return }
            await vm.load(id: entryId, token: token)
        }
        .overlay { if vm.showPopup { highlightPopup } }
    }

    /// The video surface + loading state + the caption / CC-toggle overlays.
    /// Sizing (16:9 box vs fullscreen fill) is applied by the caller.
    private func player(_ entry: LibraryEntryDetail, fullscreen: Bool) -> some View {
        ZStack {
            if let v = entry.videoUrl, let url = URL(string: v) {
                VideoPlayerView(
                    url: url,
                    seek: vm.seek,
                    onReady: { playerReady = true },
                    onTime: { sec in vm.onPlayerTime(sec) }
                )
            } else {
                YouTubeEmbedView(
                    videoId: entry.youtubeId,
                    seek: vm.seek,
                    onReady: { playerReady = true },
                    onTime: { sec in vm.onPlayerTime(sec) }
                )
            }
            if !playerReady { playerOverlay(isYouTube: entry.videoUrl == nil) }
            if playerReady {
                VStack {
                    HStack { Spacer(); captionToggle }
                    Spacer()
                    if showCaptions, let cue = vm.currentCue { captionBar(cue) }
                }
                .padding(fullscreen ? 16 : 8)
            }
        }
        .background(Color.black)
        .task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !playerReady { playerTimedOut = true }
        }
    }

    // On-video bilingual caption (current cue): English with AI highlights in
    // yellow + Chinese below. Toggleable via the CC button.
    private func captionBar(_ cue: Cue) -> some View {
        VStack(spacing: 3) {
            captionEnglish(cue)
                .font(.system(size: 17, weight: .medium))
                .multilineTextAlignment(.center)
            if !cue.translation.isEmpty {
                Text(cue.translation)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private func captionEnglish(_ cue: Cue) -> Text {
        splitForHighlights(cue.text, highlights: cue.highlightWords).reduce(Text("")) { acc, run in
            acc + Text(run.text)
                .foregroundColor(run.highlight ? .whatsubHighlight : .white)
                .fontWeight(run.highlight ? .semibold : .regular)
        }
    }

    private var captionToggle: some View {
        Button { showCaptions.toggle() } label: {
            Image(systemName: showCaptions ? "captions.bubble.fill" : "captions.bubble")
                .font(.title3)
                .foregroundColor(.white)
                .padding(8)
                .background(.black.opacity(0.45), in: Circle())
        }
    }

    private func playerOverlay(isYouTube: Bool) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                if playerTimedOut {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title)
                        .foregroundStyle(.whatsubInkMuted)
                    Text("视频加载失败")
                        .font(.callout)
                        .foregroundStyle(.whatsubInk)
                    Text(isYouTube ? "YouTube 视频需挂 VPN 观看，\n确认 VPN 已开启后重进本页" : "请检查网络后重进本页")
                        .font(.caption)
                        .foregroundStyle(.whatsubInkMuted)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                        .tint(.whatsubAccent)
                    Text("视频加载中…")
                        .font(.callout)
                        .foregroundStyle(.whatsubInkSoft)
                    if isYouTube {
                        Text("YouTube 视频需挂 VPN 观看")
                            .font(.caption)
                            .foregroundStyle(.whatsubInkFaint)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func portrait(_ entry: LibraryEntryDetail) -> some View {
        VStack(spacing: 0) {
            player(entry, fullscreen: false)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            subtitleList(entry)
        }
    }

    // Landscape = fullscreen: the player fills the screen (video letterboxed on
    // black); the on-video caption overlay is the reading surface here (no list).
    private func landscape(_ entry: LibraryEntryDetail) -> some View {
        player(entry, fullscreen: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
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
