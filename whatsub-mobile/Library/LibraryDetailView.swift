import SwiftUI
import AVFoundation

struct LibraryDetailView: View {
    let entryId: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryDetailViewModel()
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.scenePhase) private var scenePhase
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
    /// 2026-06-18: 取消编辑 confirmation when there are unsaved drafts.
    /// Skipping the alert when `!vm.dirty` lets users back out of an
    /// untouched edit session without a noisy "are you sure" prompt.
    @State private var confirmCancelEdit: Bool = false
    @State private var confirmDesktopReplacement: Bool = false
    @State private var showDesktopReplacementSheet: Bool = false
    enum ContentTab: String, Hashable, CaseIterable { case subtitles, collections, roleplay }
    // (showPendingSheet + 「待同步 N 条」 banner removed 2026-06-07.
    // PendingPhraseStore is still used — observed inside
    // EntryCollectionsList now, where each pending phrase has its own
    // ☁️ upload button.)

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
        .toolbar {
            if vm.entry?.needsDesktopDownload == true {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showDesktopReplacementSheet = true
                    } label: {
                        desktopReplacementToolbarIcon
                    }
                    .accessibilityLabel("发送到桌面端下载")
                }
            }
        }
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
        .onChange(of: vm.entry?.videoUrl) { newValue in
            // Replacement completion is discovered by an ordinary detail
            // refresh. Swap from YouTube embed to native AVPlayer once; later
            // signed-URL refreshes must not interrupt current playback.
            guard avPlayer == nil,
                  let newValue,
                  let url = URL(string: newValue) else { return }
            playerReady = false
            playerTimedOut = false
            let player = AVPlayer(url: url)
            player.automaticallyWaitsToMinimizeStalling = false
            avPlayer = player
        }
        .onChange(of: scenePhase) { phase in
            // One foreground refresh is enough to discover desktop completion;
            // no detail polling loop is added.
            guard phase == .active, vm.entry?.needsDesktopDownload == true else { return }
            Task { await reloadDetail() }
        }
        .sheet(isPresented: $showDesktopReplacementSheet) {
            desktopReplacementSheet
                .presentationDetents([.medium, .large])
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
        // Pause whenever this view leaves the screen — covers:
        //   • bottom TabView switch (Library → 语料库 / 我的): without this
        //     the audio kept playing in the background. Users complained
        //     the video "follows them" across tabs.
        //   • navigation pop back to the Library list (cleanest: back arrow
        //     killed sound but video frame stays implied; this aligns both).
        // Does NOT fire on sheet presentation (sheets keep the underlying
        // view alive) so shadow / cloze / collect / roleplay sheets continue
        // to work — their own logic handles pause/resume as needed.
        // Does NOT fire on portrait↔landscape rotation either — that's the
        // same SwiftUI view re-laid-out, not torn down.
        // Position stays at the paused timestamp, so resuming the video by
        // tapping play continues from where the user left off.
        .onDisappear { avPlayer?.pause() }
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
                    // Feed Now Playing center metadata for the lock-screen
                    // card (when the user has 「锁屏继续播放」 on). Title
                    // is on the detail payload. The thumb endpoint isn't
                    // exposed on LibraryEntryDetail directly (only on the
                    // list payload), so we reconstruct it here using the
                    // same URL pattern the backend serves from the list —
                    // `whatsub.eversay.cc/api/library/thumb/<id>` returns
                    // the OSS-uploaded JPEG for synced videos and 404s
                    // cleanly otherwise (Now Playing card just shows
                    // title without artwork in that case).
                    title: entry.title,
                    thumbURL: URL(string: "https://whatsub.eversay.cc/api/library/thumb/\(entry.id)"),
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
                // (pendingBanner removed 2026-06-07 — pending phrases are
                // now rendered inline inside the 收藏 tab below, with a
                // per-row ☁️ upload button. A top-of-page banner +
                // separate sheet was redundant.)
                contentArea(entry)
                    .refreshable { await reloadDetail() }
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
                EntryCollectionsList(
                    entryId: entryId,
                    youtubeId: vm.entry?.youtubeId,
                    onTapPhrase: { sec in vm.seekTo(seconds: sec) }
                )
            case .roleplay:
                // Pause the underlying video the moment the user opens a
                // roleplay session — the orb wants the user's mic free of
                // competing audio. Not auto-resumed on dismiss; the user
                // taps play themselves if they want the video back.
                RoleplayTabView(entry: entry, onSessionStart: { avPlayer?.pause() })
            }
        }
    }

    @ViewBuilder
    private var desktopReplacementToolbarIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "desktopcomputer")
                .font(.body.weight(.medium))

            switch DesktopReplacementToolbarPresentation.indicator(
                state: vm.desktopReplacementState,
                activeStatus: vm.activeReplacementStatus
            ) {
            case .none:
                EmptyView()
            case .progress:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .offset(x: 7, y: -7)
            case .failure:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .offset(x: 7, y: -7)
            }
        }
        .frame(width: 26, height: 24)
    }

    private var desktopReplacementSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(activeReplacementText ?? "下载后免 VPN 播放")
                                .font(.headline)
                                .foregroundStyle(.whatsubInk)
                            Text("需要电脑上的 whatSub 在线处理。完成后会替换视频文件、字幕和解析结果；Library 条目与已收藏内容仍会保持关联。")
                                .font(.subheadline)
                                .foregroundStyle(.whatsubInkMuted)
                        }
                    } icon: {
                        Image(systemName: "desktopcomputer")
                            .font(.title2)
                            .foregroundStyle(.whatsubAccent)
                    }

                    if case .failed(let message) = vm.desktopReplacementState {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if case .queued(let desktopOffline) = vm.desktopReplacementState {
                        if desktopOffline {
                            desktopOfflineWarning
                        } else {
                            Text("检测到桌面端在线，马上会自动开始下载、解析。可在「我的 → 导入队列」查看进度。")
                                .font(.subheadline)
                                .foregroundStyle(.whatsubInkMuted)
                        }
                    }

                    Button {
                        confirmDesktopReplacement = true
                    } label: {
                        HStack(spacing: 8) {
                            if vm.desktopReplacementState == .sending {
                                ProgressView().controlSize(.small)
                            }
                            Text(activeReplacementText ?? "发送到桌面端下载")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.whatsubAccent)
                    .disabled(replacementActionDisabled)
                }
                .padding(20)
            }
            .background(Color.whatsubBg)
            .navigationTitle("桌面端下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showDesktopReplacementSheet = false }
                }
            }
        }
        .confirmationDialog(
            "发送到桌面端下载？",
            isPresented: $confirmDesktopReplacement,
            titleVisibility: .visible
        ) {
            Button("发送到桌面端下载") {
                guard let token = appState.session?.sessionToken else { return }
                Task {
                    await vm.enqueueReplacement(
                        maxVideoSeconds: appState.currentUser?.libraryLimits?.maxVideoSeconds,
                        token: token,
                        email: appState.session?.email
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("需要打开电脑上的 whatSub 并登录同一账号。桌面端会重新下载、转写和解析视频；完成后将原子替换当前视频文件、字幕和解析结果。Library 条目身份与已收藏内容仍会保持关联。")
        }
    }

    private var activeReplacementText: String? {
        switch vm.activeReplacementStatus {
        case .some(.pending): return "已发送，等待桌面端"
        case .some(.processing): return "桌面端处理中"
        case .none: return nil
        }
    }

    private var replacementActionDisabled: Bool {
        if vm.activeReplacementStatus != nil { return true }
        return vm.desktopReplacementState == .sending
    }

    private var desktopOfflineWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("你的桌面端似乎不在线", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.yellow)
            Text("任务已排队，但只有打开电脑上的 whatSub 并登录同一账号（\(appState.session?.email ?? "当前账号")）后才会开始下载和解析。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInk)

            Button("查看导入队列") {
                showDesktopReplacementSheet = false
                appState.selectedTab = 3
                appState.meShowImportQueue = true
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(.whatsubAccent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
    }

    private func reloadDetail() async {
        guard let token = appState.session?.sessionToken else { return }
        await vm.load(id: entryId, token: token)
    }

    // Landscape = fullscreen: the player fills the screen (video letterboxed on
    // black); the on-video caption overlay is the reading surface here (no list).
    private func landscape(_ entry: LibraryEntryDetail) -> some View {
        player(entry, fullscreen: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }

    private func subtitleList(_ entry: LibraryEntryDetail) -> some View {
        Group {
            if vm.editMode {
                editingSubtitleList
            } else {
                readingSubtitleList(entry)
            }
        }
    }

    private func readingSubtitleList(_ entry: LibraryEntryDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // "编辑字幕" entry point — kept above the list (vs. in the
                    // nav toolbar) so it's discoverable on first scroll. Only
                    // visible on the 字幕 tab; vanishes on 收藏 / 角色扮演.
                    Button {
                        vm.startEditing()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "pencil")
                            Text("编辑字幕（修字 / 删 / 调顺序）")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.whatsubAccent)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.whatsubAccent.opacity(0.10))
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    ForEach(entry.analysisJson.subtitles) { cue in
                        CueRow(
                            cue: cue,
                            isCurrent: cue.index == vm.currentIndex,
                            onTapCue: { vm.seekTo(cue) },
                            onTapHighlight: { w, t, n, cue in
                                // Build the gloss WITH a save context so the
                                // sheet's 「加入待同步暂存」 button can fire a
                                // PendingPhrase straight from the popup —
                                // shortcut for users who like the highlight
                                // gloss and want to collect it without going
                                // through the long-press CollectSheet flow.
                                glossWord = WordGloss(
                                    word: w,
                                    translation: t,
                                    note: n,
                                    saveContext: vm.entry.map { e in
                                        WordGloss.SaveContext(
                                            entryId: e.id,
                                            videoTitle: e.title,
                                            youtubeId: e.youtubeId,
                                            contextSentence: cue.text,
                                            timestampSec: cue.time
                                        )
                                    }
                                )
                            },
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

    /// Edit mode: per-row TextFields + swipe-to-delete + Save / Cancel
    /// bar. Uses List (not LazyVStack) because .swipeActions only fires
    /// inside List. Save error surfaces inline at the top so the user
    /// doesn't have to dismiss an alert to retry.
    @ViewBuilder
    private var editingSubtitleList: some View {
        VStack(spacing: 0) {
            // Sticky action bar with cancel / save + dirty indicator.
            HStack(spacing: 12) {
                Button("取消") {
                    if vm.dirty {
                        confirmCancelEdit = true
                    } else {
                        vm.cancelEditing()
                    }
                }
                .foregroundStyle(.whatsubInkSoft)
                Spacer()
                if vm.saving {
                    ProgressView().controlSize(.small).tint(.whatsubAccent)
                    Text("保存中…").font(.footnote).foregroundStyle(.whatsubInkMuted)
                } else if vm.dirty {
                    Text("已改动").font(.footnote).foregroundStyle(.whatsubAccent)
                }
                Button {
                    Task {
                        guard let token = appState.session?.sessionToken else { return }
                        await vm.saveEdits(token: token)
                    }
                } label: {
                    Text("保存").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.whatsubAccent)
                .disabled(!vm.dirty || vm.saving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.whatsubBgSoft)

            if let err = vm.saveError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }

            List {
                ForEach(Array(vm.draftCues.enumerated()), id: \.offset) { idx, cue in
                    CueRowEditing(
                        index: idx,
                        cue: cue,
                        canMergeUp: idx > 0,
                        isAnalyzing: vm.analyzingCueIndex == idx,
                        onTextChange: { vm.updateCueText(at: idx, text: $0) },
                        onTranslationChange: { vm.updateCueTranslation(at: idx, translation: $0) },
                        onMergeUp: { vm.mergeCueWithPrevious(at: idx) },
                        onSplit: { vm.splitCue(at: idx) },
                        onReanalyze: { Task { await vm.reanalyzeCue(at: idx) } }
                    )
                    .listRowBackground(Color.whatsubBg)
                    .listRowSeparatorTint(Color.white.opacity(0.06))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            vm.deleteCue(at: idx)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.whatsubBg)
        }
        .alert("放弃改动?", isPresented: $confirmCancelEdit) {
            Button("放弃", role: .destructive) { vm.cancelEditing() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("已修改的内容将丢失。")
        }
    }

}
