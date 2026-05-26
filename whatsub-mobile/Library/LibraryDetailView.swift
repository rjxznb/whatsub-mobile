import SwiftUI
import AVFoundation

struct LibraryDetailView: View {
    let entryId: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryDetailViewModel()
    @Environment(\.verticalSizeClass) private var vSize
    @State private var playerReady = false
    @State private var playerTimedOut = false
    @State private var showCaptions = true
    /// Owned here (not inside VideoPlayerView) so the AVPlayer survives the
    /// portrait↔landscape rebuild — playback continues across rotation instead
    /// of restarting at 0. (Named avPlayer to avoid clashing with the
    /// `player(_:fullscreen:)` view builder below.)
    @State private var avPlayer: AVPlayer?

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
        // Landscape = fullscreen: hide the nav bar + tab bar + status bar so the
        // video is truly edge-to-edge; portrait restores them.
        .toolbar(isLandscape ? .hidden : .automatic, for: .navigationBar)
        .toolbar(isLandscape ? .hidden : .automatic, for: .tabBar)
        .statusBarHidden(isLandscape)
        .task {
            guard let token = appState.session?.sessionToken else { return }
            await vm.load(id: entryId, token: token)
            // Create the AVPlayer once the OSS videoUrl is known; held in @State
            // so a portrait↔landscape rebuild reuses it (playback continues)
            // rather than spawning a new player from 0.
            if avPlayer == nil, let v = vm.entry?.videoUrl, let url = URL(string: v) {
                avPlayer = AVPlayer(url: url)
            }
        }
        .overlay { if vm.showPopup { highlightPopup } }
    }

    /// The video surface + loading state + the caption / CC-toggle overlays.
    /// Sizing (16:9 box vs fullscreen fill) is applied by the caller.
    private func player(_ entry: LibraryEntryDetail, fullscreen: Bool) -> some View {
        ZStack {
            if let p = avPlayer {
                VideoPlayerView(
                    player: p,
                    seek: vm.seek,
                    currentCue: vm.currentCue,
                    showCaptions: showCaptions,
                    onToggleCaptions: { showCaptions.toggle() },
                    onReady: { playerReady = true },
                    onTime: { sec in vm.onPlayerTime(sec) }
                )
            } else if entry.videoUrl == nil, VideoSource.isLikelyYouTubeId(entry.youtubeId) {
                YouTubeEmbedView(
                    videoId: entry.youtubeId,
                    seek: vm.seek,
                    onReady: { playerReady = true },
                    onTime: { sec in vm.onPlayerTime(sec) }
                )
            } else if entry.videoUrl == nil {
                desktopOnlyPlaceholder
            }
            // (videoUrl present but player not yet created → nothing here; the
            // loading overlay below covers that brief window.)
            if !playerReady && !isDesktopOnly(entry) { playerOverlay(isYouTube: entry.videoUrl == nil) }
        }
        .background(Color.black)
        .task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !playerReady { playerTimedOut = true }
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

    /// True when there is no OSS video AND the id isn't a real YouTube id —
    /// i.e. a queue import whose video isn't on OSS (still processing / failed).
    private func isDesktopOnly(_ entry: LibraryEntryDetail) -> Bool {
        entry.videoUrl == nil && !VideoSource.isLikelyYouTubeId(entry.youtubeId)
    }

    private var desktopOnlyPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.title)
                .foregroundStyle(.whatsubInkMuted)
            Text("此视频需在桌面端查看")
                .font(.callout)
                .foregroundStyle(.whatsubInk)
            Text("云端尚无可播放的视频文件（可能仍在桌面端处理）。")
                .font(.caption)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
