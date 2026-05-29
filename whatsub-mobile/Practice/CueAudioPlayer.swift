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
    /// When non-nil, this player is owned by a parent view (the LibraryDetail
    /// avPlayer) — we MUST restore its state on deinit instead of leaving it
    /// scrubbed to the cue's position with a tiny forwardPlaybackEndTime.
    /// When nil, the player is ours; we just stop it on teardown.
    private let savedState: SavedSharedState?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endTime: Double = 0

    private struct SavedSharedState {
        let time: CMTime
        let rate: Float
        let forwardEndTime: CMTime
    }

    /// Two construction modes:
    /// - **Shared** (`sharedPlayer:` non-nil): wraps the parent view's AVPlayer.
    ///   No new HTTP fetch, no re-parsing of OSS moov, no re-buffering — re-uses
    ///   whatever data the main video player has already loaded. The parent's
    ///   playback state is snapshotted + restored on deinit so closing the
    ///   practice sheet leaves the main video where the user had it.
    ///   This is the primary path from LibraryDetailView and fixes the
    ///   "进去之后一直 loading 一分钟" issue on big videos (2026-05-29).
    /// - **Standalone** (`videoURL:` only): builds its own AVPlayer. Used as
    ///   fallback when no shared player is available (offline / unusual entry).
    init(sharedPlayer: AVPlayer? = nil, videoURL: URL? = nil) {
        if let shared = sharedPlayer {
            self.player = shared
            self.savedState = SavedSharedState(
                time: shared.currentTime(),
                rate: shared.rate,
                forwardEndTime: shared.currentItem?.forwardPlaybackEndTime ?? .invalid
            )
            // Pause main playback while the practice sheet is up — the cue
            // snippet would otherwise overlap with whatever's still playing.
            shared.pause()
        } else if let url = videoURL {
            let item = AVPlayerItem(url: url)
            self.player = AVPlayer(playerItem: item)
            self.savedState = nil
        } else {
            // Last-resort no-op player. Sheets handle the no-audio case in UI
            // (disabled play button), so this just keeps the type contract.
            self.player = AVPlayer()
            self.savedState = nil
        }
        // Wait for stalling = false caused the audio-out delay to be silent
        // (no buffering indication at all). Flip to true so AVPlayer reports
        // .waitingToPlayAtSpecifiedRate while it buffers — UI picks that up
        // via the KVO observer below.
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
        if let saved = savedState {
            // Shared player — pause + restore the parent's position so the
            // main video isn't stuck at the practice cue's time when the
            // sheet closes. forwardPlaybackEndTime back to .positiveInfinity
            // (the default) so main playback can resume past the cue's end.
            player.pause()
            player.currentItem?.forwardPlaybackEndTime =
                saved.forwardEndTime.isValid ? saved.forwardEndTime : .positiveInfinity
            player.seek(to: saved.time, toleranceBefore: .zero, toleranceAfter: .zero)
            // Don't auto-resume — let the user re-tap play on the main view if
            // they want to keep watching. Auto-resuming would surprise them
            // mid-conversation about the cue they just practiced.
        } else {
            player.pause()
        }
    }
}
