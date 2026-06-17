import AVFoundation
import MediaPlayer
import UIKit

/// Manages the iOS Now Playing Center + Remote Command Center + the
/// background-pause-on-lock policy for the main Library video player.
/// Owned process-wide as a singleton because the system surfaces it serves
/// (lock-screen card, control center, AirPods/CarPlay) are themselves
/// process-wide — only one "currently playing" item across the OS at a
/// time, so there's no benefit to per-view instances.
///
/// **App Review history (2026-06-09 → 2026-06-17)**: Guideline 2.5.4
/// originally rejected `UIBackgroundModes: audio` for v0.0.1 because the
/// reviewer "couldn't find a persistent-audio feature." The entitlement
/// was removed. This coordinator + the user-facing 「锁屏继续播放」 toggle
/// in MeView are the justification for re-adding it: a clear opt-in
/// surface, real Now Playing metadata + Remote Command handlers, and an
/// honest "language-learning audio" use case. ASC review notes for the
/// next submission should call out the MeView toggle path.
///
/// **Policy** for what happens when the user backgrounds the app while a
/// video is playing:
///   - Toggle ON  → AVPlayer keeps emitting audio, lock screen shows the
///                  Now Playing card, audio survives screen lock + home
///                  swipe-up. AVAudioSession stays in `.playback`.
///   - Toggle OFF → We pause the player on `didEnterBackground`. Audio
///                  goes silent; Now Playing card is cleared. Matches
///                  the pre-2026-06-17 behavior so users who don't opt
///                  in see no change.
///
/// Silent switch is intentionally ignored regardless of toggle (.playback
/// category). This matches the YouTube/B 站 expectation for video apps —
/// users don't expect mute switch to kill the sound while they're actively
/// watching a video.
@MainActor
final class BackgroundAudioCoordinator {

    static let shared = BackgroundAudioCoordinator()

    /// UserDefaults key for the MeView toggle. Read here so the
    /// coordinator stays self-contained — no @AppStorage import chain.
    static let preferenceKey = "playback.background.enabled"

    private var currentPlayer: AVPlayer?
    private var currentTitle: String = ""
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var artworkTask: Task<Void, Never>?
    /// Remote Command Center handlers register once for the app lifetime.
    /// Subsequent `bind()` calls just update `currentPlayer`; handlers
    /// dispatch to whichever player is currently bound. Without this
    /// guard, every entry-open stacks another set of handlers.
    private var commandsRegistered = false
    private var backgroundObserver: NSObjectProtocol?

    private init() {
        // Observe background entry so we can honor the user's opt-out
        // (pause player on lock) without bringing UIApplication into
        // every view that uses VideoPlayerView. Set up once per process.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The MainActor hop is needed because `currentPlayer` is
            // MainActor-isolated. NotificationCenter delivers on whatever
            // queue the publisher is on (.main here, but defensive).
            Task { @MainActor [weak self] in self?.handleEnterBackground() }
        }
    }

    /// Returns true if the user has explicitly enabled background playback
    /// in MeView. Default false — the App Store review-friendly stance.
    var isBackgroundPlaybackEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.preferenceKey)
    }

    /// Wire the system Now Playing surfaces to this video. Call when a
    /// video starts playing. Replaces any prior binding (the OS only
    /// surfaces ONE Now Playing item across the whole device at a time).
    func bind(player: AVPlayer, title: String, thumbURL: URL?) {
        teardown(clearNowPlaying: false)
        currentPlayer = player
        currentTitle = title
        ensureCommandsRegistered()
        setNowPlayingMetadata(title: title)
        attachTimeObserver()
        loadArtwork(from: thumbURL)
    }

    /// Drop the binding. Called from VideoPlayerView's dismantle path
    /// (user navigates back from Library detail). Clears the Now Playing
    /// card so a stale "previous video" doesn't linger on the lock
    /// screen after the user has obviously moved on.
    func teardown(clearNowPlaying: Bool = true) {
        if let p = currentPlayer, let obs = timeObserver {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil
        artworkTask?.cancel()
        artworkTask = nil
        currentPlayer = nil
        currentTitle = ""
        if clearNowPlaying {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    // MARK: - Internals

    private func handleEnterBackground() {
        // User hasn't opted in → pause the player. With UIBackgroundModes
        // audio declared, iOS WOULD let audio keep playing here; this is
        // the policy enforcement that respects the toggle.
        if !isBackgroundPlaybackEnabled {
            currentPlayer?.pause()
            // Don't clear Now Playing — the user might foreground and
            // hit play from the lock screen card.
        }
    }

    private func ensureCommandsRegistered() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let p = self?.currentPlayer else { return .commandFailed }
            p.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let p = self?.currentPlayer else { return .commandFailed }
            p.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let p = self?.currentPlayer else { return .commandFailed }
            if p.rate > 0 { p.pause() } else { p.play() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let p = self?.currentPlayer else { return .commandFailed }
            let t = p.currentTime().seconds + 15
            p.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let p = self?.currentPlayer else { return .commandFailed }
            let t = max(0, p.currentTime().seconds - 15)
            p.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let p = self?.currentPlayer,
                  let e = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            p.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600))
            return .success
        }
    }

    private func setNowPlayingMetadata(title: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "whatSub",
        ]
        if let p = currentPlayer {
            if let duration = p.currentItem?.duration.seconds,
               duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime().seconds
            info[MPNowPlayingInfoPropertyPlaybackRate] = p.rate
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func attachTimeObserver() {
        guard let p = currentPlayer else { return }
        // 1Hz is the cadence Apple uses internally for Now Playing
        // updates — finer would be wasted (lock-screen scrubber UI
        // doesn't render sub-second), coarser would visibly stutter.
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self, let p = self.currentPlayer else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t.seconds
            info[MPNowPlayingInfoPropertyPlaybackRate] = p.rate
            // Duration may become known after the metadata first load —
            // back-fill if it wasn't in the initial bind() snapshot.
            if info[MPMediaItemPropertyPlaybackDuration] == nil,
               let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = d
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        // Catch rate changes outside of the periodic tick (e.g., the
        // lock-screen play/pause button flips rate before the next
        // 1Hz tick fires). Without this, the lock-screen icon would
        // briefly disagree with the player state.
        rateObserver = p.observe(\.rate, options: [.new]) { [weak self] p, _ in
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPNowPlayingInfoPropertyPlaybackRate] = p.rate
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private func loadArtwork(from url: URL?) {
        guard let url else { return }
        artworkTask = Task { [weak self, currentTitle = currentTitle] in
            // Bypass URLCache here too — same reasoning as RemoteImage.
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 8
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let img = UIImage(data: data) else { return }
            await MainActor.run {
                guard let self else { return }
                // Defensive: a rapid swap (user navigated away while
                // artwork was loading) would otherwise paint a stale
                // image onto the NEW Now Playing entry. Compare title
                // we captured at task start vs. current.
                guard self.currentTitle == currentTitle else { return }
                let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
