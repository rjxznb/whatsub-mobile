import SwiftUI
import AVKit
import AVFoundation

/// Native AVPlayer-backed video view. Input surface mirrors YouTubeEmbedView
/// (url, seek, onReady, onTime) so LibraryDetailView can swap between them
/// without changing the view model.
struct VideoPlayerView: UIViewControllerRepresentable {
    /// The AVPlayer is OWNED by the parent (LibraryDetailView @State), not created
    /// here — so it survives the portrait↔landscape view rebuild. Creating it in
    /// makeUIViewController would make rotation spawn a fresh player (restart at 0).
    let player: AVPlayer
    var seek: SeekRequest?
    var onReady: () -> Void
    var onTime: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onTime: onTime) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // Play audio even when the hardware ring/silent switch is on silent.
        // Default AVAudioSession (.ambient/.soloAmbient) honors the silent
        // switch → muted video. `.playback` is the standard category for a
        // media app and makes the sound audible regardless of the switch.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        player.automaticallyWaitsToMinimizeStalling = true
        let vc = AVPlayerViewController()
        vc.player = player
        vc.videoGravity = .resizeAspect
        vc.showsPlaybackControls = true
        context.coordinator.attach(player: player)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        guard let seek, seek != context.coordinator.lastSeek else { return }
        context.coordinator.lastSeek = seek
        let t = CMTime(seconds: seek.seconds, preferredTimescale: 600)
        vc.player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        vc.player?.play()
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        let onReady: () -> Void
        let onTime: (Double) -> Void
        var lastSeek: SeekRequest?
        private weak var player: AVPlayer?
        private var timeObserver: Any?
        private var statusObs: NSKeyValueObservation?
        private var didReady = false

        init(onReady: @escaping () -> Void, onTime: @escaping (Double) -> Void) {
            self.onReady = onReady; self.onTime = onTime
        }
        func attach(player: AVPlayer) {
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] t in self?.onTime(t.seconds) }
            statusObs = player.observe(\.status, options: [.new]) { [weak self] p, _ in
                guard let self, !self.didReady, p.status == .readyToPlay else { return }
                self.didReady = true; self.onReady()
            }
        }
        func detach() {
            if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
            statusObs?.invalidate(); statusObs = nil
        }
        deinit { detach() }
    }
}
