import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// Native AVPlayer-backed video view. Input surface mirrors YouTubeEmbedView
/// (player, seek, onReady, onTime) so LibraryDetailView can swap between them
/// without changing the view model.
///
/// Captions render into `AVPlayerViewController.contentOverlayView` — a UIKit view
/// that IS part of the player's NATIVE fullscreen presentation. A SwiftUI overlay
/// (the old approach) vanished when the user tapped the native fullscreen button,
/// notably on iPad, which never enters the app's custom-landscape layout.
struct VideoPlayerView: UIViewControllerRepresentable {
    /// The AVPlayer is OWNED by the parent (LibraryDetailView @State), not created
    /// here — so it survives the portrait↔landscape view rebuild. Creating it in
    /// makeUIViewController would make rotation spawn a fresh player (restart at 0).
    let player: AVPlayer
    var seek: SeekRequest?
    /// Current bilingual cue to show as an on-video caption (nil = none).
    var currentCue: Cue?
    /// CC toggle — when false the caption is hidden.
    var showCaptions: Bool
    /// Video title — fed into the system Now Playing Center so the lock-
    /// screen / Control Center card shows the video name (for users who've
    /// turned on 「锁屏继续播放」 in MeView). Empty string disables the
    /// Now Playing card entirely. See `BackgroundAudioCoordinator`.
    var title: String = ""
    /// Optional thumbnail URL — asynchronously loaded and pushed into
    /// MPMediaItemArtwork so the lock-screen card has cover art. Skipped
    /// when nil. Fetched via URLSession with cache-bypass for the same
    /// reasons RemoteImage avoids URLCache (VPN-induced cache poisoning).
    var thumbURL: URL? = nil
    var onReady: () -> Void
    var onTime: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onTime: onTime) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // Play audio even when the hardware ring/silent switch is on silent.
        // `.playback` is also the category that allows background audio
        // (paired with UIBackgroundModes: audio in project.yml) when the
        // user has opted in via MeView's 「锁屏继续播放」 toggle.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        player.automaticallyWaitsToMinimizeStalling = true
        let vc = AVPlayerViewController()
        vc.player = player
        vc.videoGravity = .resizeAspect
        vc.showsPlaybackControls = true
        // PiP intentionally kept OFF this round. The 「锁屏继续播放」
        // feature (re-add of UIBackgroundModes: audio + Now Playing
        // center) provides the primary user-facing surface for "keep
        // playing while screen off"; PiP would be a separate ask that
        // App Review previously called out as not-a-primary-feature.
        // Revisit if users specifically ask for the floating-window UX.
        vc.allowsPictureInPicturePlayback = false
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        // 2026-06-18 — disable AVPlayerViewController's automatic Now Playing
        // integration. Default is true, in which case AVPlayerViewController
        // periodically REPLACES the entire MPNowPlayingInfoCenter.nowPlayingInfo
        // dict with one that has time/duration/rate ONLY — wiping the title +
        // artist + artwork that BackgroundAudioCoordinator manually set. User
        // report: lock screen card showed progress bar working but title +
        // thumb area was blank. Same path also stomps the ±15s skip
        // intervals we set on MPRemoteCommandCenter (lock screen shows the
        // default ±10s). Our Coordinator owns the whole now-playing surface;
        // ATV's auto-integration would only fight us.
        vc.updatesNowPlayingInfoCenter = false
        context.coordinator.attach(player: player)
        // Wire the Now Playing card + Remote Command Center to this video.
        // Done here (vs. higher up at LibraryDetailView level) so the
        // teardown stays paired with this view controller's lifecycle —
        // when the user backs out, the lock screen card clears with us.
        if !title.isEmpty {
            BackgroundAudioCoordinator.shared.bind(
                player: player,
                title: title,
                thumbURL: thumbURL
            )
        }
        // Force the view tree to load so contentOverlayView is non-nil, then
        // attach the caption eagerly (updateUIViewController also ensures it).
        vc.loadViewIfNeeded()
        context.coordinator.ensureCaptionView(in: vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        // Caption first (always), then the seek (which can early-return).
        context.coordinator.ensureCaptionView(in: vc)
        context.coordinator.updateCaption(cue: currentCue, show: showCaptions)
        guard let seek, seek != context.coordinator.lastSeek else { return }
        context.coordinator.lastSeek = seek
        let t = CMTime(seconds: seek.seconds, preferredTimescale: 600)
        vc.player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        vc.player?.play()
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detach()
        // Clear the Now Playing card too — user navigated away from this
        // video, the lock screen shouldn't keep displaying its title.
        BackgroundAudioCoordinator.shared.teardown()
    }

    final class Coordinator {
        let onReady: () -> Void
        let onTime: (Double) -> Void
        var lastSeek: SeekRequest?
        private weak var player: AVPlayer?
        private var timeObserver: Any?
        private var statusObs: NSKeyValueObservation?
        private var didReady = false
        // Caption UI lives in the player's contentOverlayView so it shows in
        // native fullscreen too.
        private var captionContainer: UIView?
        private var captionLabel: UILabel?
        private var lastCaptionKey: String?

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

        /// Build the caption container inside the player's contentOverlayView once
        /// (idempotent). contentOverlayView is non-nil once the VC's view is loaded,
        /// which is guaranteed by the time updateUIViewController runs.
        func ensureCaptionView(in vc: AVPlayerViewController) {
            guard captionContainer == nil, let overlay = vc.contentOverlayView else { return }
            let container = UIView()
            container.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            container.layer.cornerRadius = 8
            container.clipsToBounds = true
            container.isUserInteractionEnabled = false   // never block player taps
            container.isHidden = true
            container.translatesAutoresizingMaskIntoConstraints = false

            let label = UILabel()
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            overlay.addSubview(container)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
                container.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                container.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -28),
                container.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 16),
                container.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -16),
            ])
            captionContainer = container
            captionLabel = label
        }

        /// Update the caption text + visibility. Deduped on cue index so the
        /// 0.25s time ticks don't rebuild the attributed string every frame.
        func updateCaption(cue: Cue?, show: Bool) {
            guard let container = captionContainer, let label = captionLabel else { return }
            let key = (show && cue != nil) ? "\(cue!.index)" : "off"
            guard key != lastCaptionKey else { return }
            lastCaptionKey = key
            if show, let cue = cue {
                label.attributedText = Self.captionAttributed(cue)
                container.isHidden = false
            } else {
                container.isHidden = true
            }
        }

        /// English (AI-highlighted words in brand yellow) + Chinese below — mirrors
        /// the old SwiftUI captionBar styling, as an NSAttributedString for UIKit.
        private static func captionAttributed(_ cue: Cue) -> NSAttributedString {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let highlight = UIColor(red: 0xFC / 255.0, green: 0xD3 / 255.0, blue: 0x4D / 255.0, alpha: 1)
            let out = NSMutableAttributedString()
            for run in splitForHighlights(cue.text, highlights: cue.highlightWords) {
                out.append(NSAttributedString(string: run.text, attributes: [
                    .font: UIFont.systemFont(ofSize: 17, weight: run.highlight ? .semibold : .medium),
                    .foregroundColor: run.highlight ? highlight : UIColor.white,
                    .paragraphStyle: para,
                ]))
            }
            if !cue.translation.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: para]))
                out.append(NSAttributedString(string: cue.translation, attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                    .paragraphStyle: para,
                ]))
            }
            return out
        }
    }
}
