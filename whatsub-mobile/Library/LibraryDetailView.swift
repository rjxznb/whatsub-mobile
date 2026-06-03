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
    /// Non-fullscreen player zoom. On iPad the player is a height-constrained 16:9
    /// box that pillarboxes (black bars) on wide screens; pinch-out scales it up
    /// to full content width. `playerZoom` is the committed value (survives
    /// rotation); `pinch` tracks the live magnification during a gesture.
    @State private var playerZoom: CGFloat = 1.0
    @GestureState private var pinch: CGFloat = 1.0
    /// Long-pressed cue → contextMenu → 收藏卡 (now writes to corpus, build 247+).
    @State private var collectCue: Cue?
    /// Long-pressed cue → contextMenu → 跟读 (shadow) sheet.
    @State private var shadowCue: Cue?
    /// Long-pressed cue → contextMenu → 听抄 (cloze) sheet.
    @State private var clozeCue: Cue?
    /// Single-tapped highlight phrase → its 释义 box (intercepts the seek).
    @State private var glossWord: WordGloss?
    /// 2026-06-03 Stage 5: portrait content tab switcher. Subtitle list is the
    /// existing default; .collections renders EntryCollectionsList scoped to
    /// this entry (corpus phrases tagged with libraryEntryId == entryId).
    @State private var contentTab: ContentTab = .subtitles
    enum ContentTab: String, Hashable, CaseIterable { case subtitles, collections, roleplay }

    private var isLandscape: Bool { vSize == .compact }

    /// Signed CDN URL for the OSS-hosted video, or nil for YouTube-fallback
    /// entries. Practice sheets fall back to this when no audio sidecar is
    /// available (entries synced before 2026-05-29).
    private var ossVideoURL: URL? {
        guard let s = vm.entry?.videoUrl else { return nil }
        return URL(string: s)
    }

    /// Signed CDN URL for the audio-only .m4a sidecar (since 2026-05-29
    /// desktop sync). Practice sheets prefer this — ~30× less bandwidth per
    /// cue than fetching MP4 byte ranges. Nil for pre-sidecar entries; sheets
    /// fall back to ossVideoURL via the shared main AVPlayer.
    private var ossAudioURL: URL? {
        guard let s = vm.entry?.audioUrl else { return nil }
        return URL(string: s)
    }

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
                let player = AVPlayer(url: url)
                // Long OSS videos used to silently swallow the first play() tap
                // — AVPlayer defaults to .automaticallyWaitsToMinimizeStalling
                // = true and stays paused-but-loading until "enough" buffer is
                // built. Users reported tapping play with no response, then
                // pause-then-play to actually start. Flipping to false makes
                // play() always respond immediately (may briefly stall if buffer
                // is truly empty, but the user sees something happen).
                player.automaticallyWaitsToMinimizeStalling = false
                avPlayer = player
            }
        }
        // (词汇本 toolbar button removed build 248+ — local vocab notebook
        // retired. Collections from this video are now in the [收藏] tab
        // below the player; long-pressing a cue writes straight to corpus.)
        .sheet(item: $collectCue) { cue in
            // Pass youtubeId so the corpus contribution records a fallback
            // for when this Library entry is later deleted (the OSS object
            // goes away but the original YouTube video usually stays up).
            // Non-YouTube Library entries (Bilibili imports) will still have
            // a non-empty youtubeId field on the LibraryEntryDetail DTO; if
            // that's actually a YT id we can fall back, otherwise the player
            // just shows "video unavailable".
            CollectSheet(
                cue: cue,
                entryId: entryId,
                videoTitle: vm.entry?.title ?? "",
                youtubeId: vm.entry?.youtubeId
            )
        }
        .sheet(item: $glossWord) { g in
            GlossSheet(gloss: g)
        }
        .sheet(item: $shadowCue) { cue in
            // Pass the small audio sidecar URL when available (preferred since
            // 2026-05-29 — ~30× less bandwidth per cue than pulling MP4 byte
            // ranges). Fallback chain: ossAudioURL → ossVideoURL via shared
            // avPlayer → standalone player built from ossVideoURL. The shared
            // avPlayer is also passed so the main video pauses + restores
            // even when we're driving a separate audio player.
            ShadowSheet(
                cue: cue,
                sharedPlayer: avPlayer,
                audioURL: ossAudioURL,
                videoURL: ossVideoURL
            )
        }
        .sheet(item: $clozeCue) { cue in
            // Same audio-sidecar preference (see ShadowSheet above). Pass
            // ALL cues (not a filtered pool) so the sheet can advance via
            // 下一句 without dismissing; ClozeSheet filters currentCue out
            // when picking distractors.
            ClozeSheet(
                cue: cue,
                allCues: vm.entry?.analysisJson.subtitles ?? [],
                sharedPlayer: avPlayer,
                audioURL: ossAudioURL,
                videoURL: ossVideoURL
            )
        }
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
            // Inline CC toggle (top-right). In native fullscreen this SwiftUI
            // overlay isn't shown, so captions there follow the current on/off.
            if playerReady {
                VStack {
                    HStack { Spacer(); captionToggle }
                    Spacer()
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
        GeometryReader { geo in
            // Height at which a 16:9 player exactly fills the content width.
            let fullWidthH = geo.size.width * 9.0 / 16.0
            // Default (zoom == 1): height-constrained, so wide screens (iPad) keep
            // the prior pillarboxed look; never wider than the content.
            let defaultH = min(fullWidthH, geo.size.height * 0.42)
            // Pinch-out ceiling: full content width, but at most 90% of the height.
            let maxH = min(fullWidthH, geo.size.height * 0.9)
            let maxZoom = defaultH > 0 ? maxH / defaultH : 1.0
            // Live height tracks the in-progress pinch; clamped to [default, max].
            let playerH = min(max(defaultH * playerZoom * pinch, defaultH), maxH)
            VStack(spacing: 0) {
                player(entry, fullscreen: false)
                    .frame(width: playerH * 16.0 / 9.0, height: playerH)
                    .frame(maxWidth: .infinity)   // center; black bars fill the rest
                    .contentShape(Rectangle())    // make the whole band pinch-able
                    .simultaneousGesture(
                        MagnificationGesture()
                            .updating($pinch) { value, state, _ in state = value }
                            .onEnded { value in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    playerZoom = min(max(playerZoom * value, 1.0), maxZoom)
                                }
                            }
                    )
                contentArea(entry)
            }
        }
    }

    @ViewBuilder
    private func contentArea(_ entry: LibraryEntryDetail) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $contentTab) {
                Text("字幕").tag(ContentTab.subtitles)
                Text("收藏").tag(ContentTab.collections)
                Text("角色扮演").tag(ContentTab.roleplay)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            switch contentTab {
            case .subtitles:
                subtitleList(entry)
            case .collections:
                EntryCollectionsList(entryId: entryId) { sec in
                    vm.seekTo(seconds: sec)
                }
            case .roleplay:
                RoleplayTabView(entry: entry)
            }
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
                            onTapHighlight: { w, t, n in glossWord = WordGloss(word: w, translation: t, note: n) },
                            onCollect: { collectCue = cue },
                            onShadow: { shadowCue = cue },
                            onCloze: { clozeCue = cue }
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

}
