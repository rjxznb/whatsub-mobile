import SwiftUI
import Foundation
import AVKit
import AVFoundation
import UIKit

enum AVPlayerLifecycleEvent: Equatable {
    case itemReady
    case itemFailed
    case didPlayToEnd
}

enum AVPlayerLifecycleDecision: Equatable {
    case ready
    case seekPaused(Double)
    case seekAndPlay(Double)
    case failure
    case ended

    static func ready(
        resumeSeconds: Double?,
        durationSeconds: Double? = nil
    ) -> AVPlayerLifecycleDecision {
        guard let resumeSeconds,
              let target = AVPlayerRestorePolicy.target(
                savedSeconds: resumeSeconds,
                durationSeconds: durationSeconds
              ) else { return .ready }
        return .seekPaused(target)
    }

    static func forEvent(_ event: AVPlayerLifecycleEvent) -> AVPlayerLifecycleDecision {
        switch event {
        case .itemReady: return .ready
        case .itemFailed: return .failure
        case .didPlayToEnd: return .ended
        }
    }

    static func explicitSeek(seconds: Double) -> AVPlayerLifecycleDecision {
        guard seconds.isFinite, seconds >= 0 else { return .ready }
        return .seekAndPlay(seconds)
    }
}

enum AVPlayerRestorePolicy {
    static let maximumSeconds: Double = 7 * 24 * 60 * 60

    static func target(savedSeconds: Double, durationSeconds: Double?) -> Double? {
        guard savedSeconds.isFinite, savedSeconds >= 0 else { return nil }
        let saved = min(savedSeconds, maximumSeconds)
        guard let durationSeconds,
              durationSeconds.isFinite,
              durationSeconds > 0 else { return saved }
        return min(saved, max(0, durationSeconds - 0.25))
    }
}

enum PlayerSeekAcceptance {
    static func av(finished: Bool, operationIsCurrent: Bool) -> Bool {
        finished && operationIsCurrent
    }

    static func javascript(resultWasTrue: Bool, errorWasNil: Bool) -> Bool {
        resultWasTrue && errorWasNil
    }
}

struct PlayerSeekDeliveryState: Equatable {
    private var isReady = false
    private var pending: SeekRequest?

    mutating func queue(_ request: SeekRequest) -> SeekRequest? {
        guard !isReady else { return request }
        pending = request
        return nil
    }

    mutating func markReady() -> SeekRequest? {
        isReady = true
        defer { pending = nil }
        return pending
    }
}

/// Parent-owned explicit seek command. A player consumes the nonce only when
/// it has actually handed the seek to its playback engine, so a SwiftUI
/// coordinator rebuild cannot replay an old command or lose a queued one.
struct PlayerSeekCommandState: Equatable {
    private(set) var pending: SeekRequest?

    mutating func submit(_ request: SeekRequest) {
        pending = request
    }

    @discardableResult
    mutating func consume(nonce: UUID) -> Bool {
        guard pending?.nonce == nonce else { return false }
        pending = nil
        return true
    }

    mutating func cancelPending() {
        pending = nil
    }
}

struct PlayerOperationRevision: Equatable {
    private var value = 0

    mutating func begin() -> Int {
        value += 1
        return value
    }

    func isCurrent(_ candidate: Int) -> Bool {
        candidate == value
    }
}

/// Shared by every coordinator wrapping the same parent-owned AVPlayer. Tokens
/// make operation completion and coordinator teardown safe in either order.
final class PlayerOperationOwner {
    private let lock = NSLock()
    private var revision = 0

    func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        revision += 1
        return revision
    }

    func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == token
    }

    @discardableResult
    func invalidate(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == token else { return false }
        revision += 1
        return true
    }

    func cancelAll() {
        lock.lock()
        revision += 1
        lock.unlock()
    }
}

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
    /// Library resume position. Restoration seeks while paused exactly once.
    var resumeSeconds: Double? = nil
    var onFailure: () -> Void = {}
    var onEnded: () -> Void = {}
    var onPlaying: () -> Void = {}
    var onSeekConsumed: (UUID) -> Void = { _ in }
    var operationOwner: PlayerOperationOwner = PlayerOperationOwner()

    func makeCoordinator() -> Coordinator {
        Coordinator(
            resumeSeconds: resumeSeconds,
            onReady: onReady,
            onTime: onTime,
            onFailure: onFailure,
            onEnded: onEnded,
            onPlaying: onPlaying,
            onSeekConsumed: onSeekConsumed,
            operationOwner: operationOwner
        )
    }

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
        guard let seek else { return }
        context.coordinator.requestExplicitSeek(seek)
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
        let onFailure: () -> Void
        let onEnded: () -> Void
        let onPlaying: () -> Void
        let onSeekConsumed: (UUID) -> Void
        let operationOwner: PlayerOperationOwner
        private let resumeSeconds: Double?
        private var lastSeek: SeekRequest?
        private weak var player: AVPlayer?
        private var timeObserver: Any?
        private var statusObs: NSKeyValueObservation?
        private var timeControlObs: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        private var didHandleItemReady = false
        private var didSignalReady = false
        private var didFail = false
        private var seekDeliveryState = PlayerSeekDeliveryState()
        private var activeOperationToken: Int?
        // Caption UI lives in the player's contentOverlayView so it shows in
        // native fullscreen too.
        private var captionContainer: UIView?
        private var captionLabel: UILabel?
        private var lastCaptionKey: String?

        init(
            resumeSeconds: Double?,
            onReady: @escaping () -> Void,
            onTime: @escaping (Double) -> Void,
            onFailure: @escaping () -> Void,
            onEnded: @escaping () -> Void,
            onPlaying: @escaping () -> Void,
            onSeekConsumed: @escaping (UUID) -> Void,
            operationOwner: PlayerOperationOwner
        ) {
            self.resumeSeconds = resumeSeconds
            self.onReady = onReady
            self.onTime = onTime
            self.onFailure = onFailure
            self.onEnded = onEnded
            self.onPlaying = onPlaying
            self.onSeekConsumed = onSeekConsumed
            self.operationOwner = operationOwner
        }
        func attach(player: AVPlayer) {
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] t in self?.onTime(t.seconds) }
            timeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                if player.timeControlStatus == .playing {
                    self?.onPlaying()
                }
            }
            guard let item = player.currentItem else {
                signalFailureOnce()
                return
            }
            statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                switch item.status {
                case .readyToPlay:
                    self?.handleReady()
                case .failed:
                    self?.handleLifecycleEvent(.itemFailed)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.handleLifecycleEvent(.didPlayToEnd)
            }
        }
        func detach() {
            if let activeOperationToken {
                operationOwner.invalidate(activeOperationToken)
                self.activeOperationToken = nil
            }
            if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
            statusObs?.invalidate(); statusObs = nil
            timeControlObs?.invalidate(); timeControlObs = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
        }
        deinit { detach() }

        private func handleReady() {
            guard !didHandleItemReady, let player else { return }
            didHandleItemReady = true
            if let pendingSeek = seekDeliveryState.markReady() {
                performExplicitSeek(pendingSeek)
                return
            }
            switch AVPlayerLifecycleDecision.ready(
                resumeSeconds: resumeSeconds,
                durationSeconds: player.currentItem?.duration.seconds
            ) {
            case .seekPaused(let seconds):
                let token = operationOwner.begin()
                activeOperationToken = token
                player.pause()
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                guard time.isValid, time.isNumeric else {
                    operationOwner.invalidate(token)
                    activeOperationToken = nil
                    signalReadyOnce()
                    return
                }
                let operationOwner = operationOwner
                player.seek(
                    to: time,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self, weak player, operationOwner] finished in
                    DispatchQueue.main.async {
                        guard finished,
                              operationOwner.isCurrent(token),
                              let player else { return }
                        player.pause()
                        if self?.activeOperationToken == token {
                            self?.activeOperationToken = nil
                        }
                        self?.signalReadyOnce()
                    }
                }
            case .ready:
                signalReadyOnce()
            default:
                break
            }
        }

        func requestExplicitSeek(_ request: SeekRequest) {
            guard request != lastSeek else { return }
            lastSeek = request
            guard let request = seekDeliveryState.queue(request) else { return }
            performExplicitSeek(request)
        }

        private func performExplicitSeek(_ request: SeekRequest) {
            guard let player,
                  case .seekAndPlay(let seconds) = AVPlayerLifecycleDecision.explicitSeek(
                    seconds: request.seconds
                  ) else { return }
            let token = operationOwner.begin()
            activeOperationToken = token
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard time.isValid, time.isNumeric else {
                operationOwner.invalidate(token)
                activeOperationToken = nil
                return
            }
            let operationOwner = operationOwner
            let acknowledge = onSeekConsumed
            let nonce = request.nonce
            player.seek(
                to: time,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak player, operationOwner] finished in
                DispatchQueue.main.async {
                    let isCurrent = operationOwner.isCurrent(token)
                    guard PlayerSeekAcceptance.av(
                        finished: finished,
                        operationIsCurrent: isCurrent
                    ), let player else { return }
                    player.play()
                    acknowledge(nonce)
                    if self?.activeOperationToken == token {
                        self?.activeOperationToken = nil
                    }
                    self?.signalReadyOnce()
                }
            }
        }

        private func signalReadyOnce() {
            guard !didSignalReady else { return }
            didSignalReady = true
            onReady()
        }

        private func signalFailureOnce() {
            guard !didFail else { return }
            didFail = true
            onFailure()
        }

        private func handleLifecycleEvent(_ event: AVPlayerLifecycleEvent) {
            switch AVPlayerLifecycleDecision.forEvent(event) {
            case .failure:
                signalFailureOnce()
            case .ended:
                onEnded()
            default:
                break
            }
        }

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
