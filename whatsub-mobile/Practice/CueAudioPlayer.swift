import AVFoundation
import Combine

/// Plays a single cue's audio snippet from the entry's OSS video URL — seeks to
/// cue.time, plays through cue.endTime, then pauses. Uses a periodic time
/// observer (not boundary, which proved flaky around very-short windows) +
/// `forwardPlaybackEndTime` as a belt-and-suspenders auto-pause.
///
/// Practice modes (跟读 / 听抄) need to replay the SAME cue many times. A new
/// AVPlayer per sheet keeps Library detail's primary player untouched (no
/// scrub clobbering) and lets the sheet release everything on dismiss.
@MainActor
final class CueAudioPlayer: ObservableObject {
    /// True only while AVPlayer is actually emitting audio (timeControlStatus
    /// = .playing). NOT true during the initial buffer of a freshly-loaded
    /// OSS video — see `isLoading`.
    @Published private(set) var isPlaying = false
    /// True between "play requested" and "audio actually emitting". Surfaces
    /// the buffering wait so the UI can show a spinner instead of a deceiving
    /// "暂停" button while a large video downloads its first range. Fix
    /// (2026-05-29): users reported "进去之后就处于播放状态但没声音" on big
    /// videos — root cause was setting isPlaying=true in the seek completion
    /// before AVPlayer had actually started decoding audio.
    @Published private(set) var isLoading = false
    @Published private(set) var ready = false

    private let player: AVPlayer
    /// True when the practice sheet owns the player it drives (audio-sidecar
    /// path or standalone URL fallback). False when we're driving the parent's
    /// main video player — in that case we must NOT stop the player on deinit
    /// (just restore its state).
    private let ownsPlayer: Bool
    /// The parent's main video player, if any, separately from `player`. We
    /// always pause + later restore the main player while practice is open,
    /// regardless of whether we use it for cue audio. With the audio sidecar
    /// (preferred path 2026-05-29), `player` is a dedicated AVPlayer for the
    /// small .m4a and `mainPlayer` is the parent's video player we just paused.
    private let mainPlayer: AVPlayer?
    private let savedMainState: SavedSharedState?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endTime: Double = 0

    private struct SavedSharedState {
        let time: CMTime
        let rate: Float
        let forwardEndTime: CMTime
        let autoWaitsToMinimizeStalling: Bool
    }

    /// Three construction modes, in priority order:
    /// 1. **Audio sidecar** (`audioURL:` non-nil): builds a dedicated AVPlayer
    ///    for the small .m4a (no buffer sharing needed — file is tiny). This
    ///    is the preferred path since 2026-05-29 — practice fetches ~3-5% of
    ///    the video bytes per cue. If `mainPlayer` is also provided, we still
    ///    pause + restore it so the main video doesn't bleed audio.
    /// 2. **Shared video player** (`mainPlayer:` non-nil, no audioURL): wraps
    ///    the parent view's AVPlayer. No new HTTP fetch, reuses the main
    ///    video's buffer. Falls back when the entry was synced before the
    ///    audio sidecar feature (audioUrl is nil server-side).
    /// 3. **Standalone** (`fallbackVideoURL:` only): builds its own AVPlayer.
    ///    Used when no shared player AND no audio sidecar (unusual entry).
    init(audioURL: URL? = nil, mainPlayer: AVPlayer? = nil, fallbackVideoURL: URL? = nil) {
        // Always snapshot + pause the main video player if provided — practice
        // shouldn't have audio overlap with whatever was playing in the detail
        // view, regardless of which player we use for cue playback.
        if let main = mainPlayer {
            self.mainPlayer = main
            self.savedMainState = SavedSharedState(
                time: main.currentTime(),
                rate: main.rate,
                forwardEndTime: main.currentItem?.forwardPlaybackEndTime ?? .invalid,
                autoWaitsToMinimizeStalling: main.automaticallyWaitsToMinimizeStalling
            )
            main.pause()
        } else {
            self.mainPlayer = nil
            self.savedMainState = nil
        }
        // Pick the player we'll actually drive for cue playback.
        if let url = audioURL {
            let item = AVPlayerItem(url: url)
            self.player = AVPlayer(playerItem: item)
            self.ownsPlayer = true
        } else if let main = mainPlayer {
            self.player = main
            self.ownsPlayer = false
        } else if let url = fallbackVideoURL {
            let item = AVPlayerItem(url: url)
            self.player = AVPlayer(playerItem: item)
            self.ownsPlayer = true
        } else {
            // Last-resort no-op player. Sheets handle the no-audio case in UI
            // (disabled play button), so this just keeps the type contract.
            self.player = AVPlayer()
            self.ownsPlayer = true
        }
        // Practice mode: prefer to surface the buffer wait via the loading
        // spinner instead of silently playing dead air. With autoWaits = true
        // AVPlayer reports .waitingToPlayAtSpecifiedRate during the wait,
        // which our KVO observer below maps to isLoading = true so the button
        // shows 加载中. Restored to the parent's original value on deinit so
        // the main video player's responsive behavior isn't lost.
        self.player.automaticallyWaitsToMinimizeStalling = true
        // Make the cue snippet routing audible from the device speaker even when
        // the silent switch is on (it's a learning drill, not background audio).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        // KVO the canonical playback state. .waitingToPlayAtSpecifiedRate = the
        // player is trying to play but doesn't have enough buffered data yet
        // (i.e., loading). .playing = real audio is going out. .paused = idle.
        statusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] p, _ in
            // KVO can fire off the main actor; hop back so the @Published
            // mutations are MainActor-safe (and SwiftUI redraws on the right queue).
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch p.timeControlStatus {
                case .paused:
                    self.isPlaying = false
                    self.isLoading = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isPlaying = false
                    self.isLoading = true
                case .playing:
                    self.isPlaying = true
                    self.isLoading = false
                @unknown default:
                    break
                }
            }
        }

        // Cheap readiness probe — once duration becomes a finite number, OSS
        // metadata has loaded enough that seek will land at the right frame.
        Task { [weak self] in
            for _ in 0..<40 { // ~2s budget
                if let d = self?.player.currentItem?.duration,
                   d.isValid, d.seconds.isFinite {
                    await MainActor.run { self?.ready = true }
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await MainActor.run { self?.ready = true } // give up; let user try anyway
        }
    }

    /// Silently seek to `start` so AVPlayer begins loading byte ranges around
    /// that position WITHOUT starting playback. The sheets call this on
    /// appear, then the user reads the cue text while buffer fills — so when
    /// they tap 听原文, the buffer at cue.time is warm and audio comes out
    /// near-instantly.
    ///
    /// Cheap to call repeatedly: AVPlayer collapses pending seeks. Safe even
    /// if the user never taps play (just a wasted seek).
    func preload(at start: Double) {
        let cm = CMTime(seconds: max(0, start), preferredTimescale: 600)
        // No isLoading flip — we're not waiting to play, just warming buffer.
        // If we set isLoading=true here the button would show 加载中 from
        // sheet open, which would confuse users who haven't tapped play yet.
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Play [cue.time, cue.endTime] then pause. Replayable by calling again.
    func play(from start: Double, to end: Double) {
        endTime = end
        // Eager isLoading flip — the KVO observer will refine to .playing once
        // AVPlayer is actually emitting audio (or back to .paused on cancel).
        // Without this, the button keeps showing "听原文" for the seek-completion
        // round-trip even though the user already tapped.
        isLoading = true
        isPlaying = false
        let startCM = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let endCM = CMTime(seconds: end + 0.05, preferredTimescale: 600) // 50ms tail
        player.currentItem?.forwardPlaybackEndTime = endCM
        player.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            // Don't set isPlaying here — let the KVO observer (timeControlStatus)
            // flip it when AVPlayer actually starts decoding+emitting audio.
            // Otherwise users see "暂停" while the OSS video is still buffering
            // its first range (could be ~1 min on big videos).
            self.player.play()
            self.attachAutoStop()
        }
    }

    func stop() {
        player.pause()
        // Eager flips for snappy tap-to-cancel; the KVO observer will also
        // fire .paused but that's a separate frame. Belt-and-suspenders.
        isPlaying = false
        isLoading = false
        if let obs = timeObserver { player.removeTimeObserver(obs); timeObserver = nil }
    }

    private func attachAutoStop() {
        // Defensive backup to forwardPlaybackEndTime — observe every 100ms and
        // pause as soon as we cross the cue's endTime. Cheap; one closure per
        // play() call, removed on stop().
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            if t.seconds >= self.endTime {
                self.stop()
            }
        }
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        // Always restore the main video player's state if we touched it
        // (regardless of whether `player` is the same instance or a separate
        // audio-sidecar player). forwardPlaybackEndTime back to
        // .positiveInfinity so main playback can resume past the cue's end.
        // autoWaits restored so LibraryDetailView's responsive-play behavior
        // (false → AVPlayerViewController's play button responds immediately)
        // survives the round-trip.
        if let main = mainPlayer, let saved = savedMainState {
            main.pause()
            main.automaticallyWaitsToMinimizeStalling = saved.autoWaitsToMinimizeStalling
            main.currentItem?.forwardPlaybackEndTime =
                saved.forwardEndTime.isValid ? saved.forwardEndTime : .positiveInfinity
            main.seek(to: saved.time, toleranceBefore: .zero, toleranceAfter: .zero)
            // Don't auto-resume — let the user re-tap play on the main view if
            // they want to keep watching.
        }
        // If our cue player is OUR OWN (audio sidecar or standalone fallback),
        // pause it. (Shared case: main player == player, already paused above.)
        if ownsPlayer { player.pause() }
    }
}
