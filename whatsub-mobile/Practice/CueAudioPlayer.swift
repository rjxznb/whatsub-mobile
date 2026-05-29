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
    @Published private(set) var isPlaying = false
    @Published private(set) var ready = false

    private let player: AVPlayer
    private var timeObserver: Any?
    private var endTime: Double = 0

    init(videoURL: URL) {
        let item = AVPlayerItem(url: videoURL)
        self.player = AVPlayer(playerItem: item)
        self.player.automaticallyWaitsToMinimizeStalling = false
        // Make the cue snippet routing audible from the device speaker even when
        // the silent switch is on (it's a learning drill, not background audio).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

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
        let startCM = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let endCM = CMTime(seconds: end + 0.05, preferredTimescale: 600) // 50ms tail
        player.currentItem?.forwardPlaybackEndTime = endCM
        player.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.player.play()
            self.isPlaying = true
            self.attachAutoStop()
        }
    }

    func stop() {
        player.pause()
        isPlaying = false
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
        player.pause()
    }
}
