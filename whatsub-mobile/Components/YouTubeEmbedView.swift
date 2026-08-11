import SwiftUI
import WebKit

enum YouTubeBridgeEvent: Equatable {
    case surfaceReady
    case ready
    case playing
    case time(Double)
    case clipEnded(UUID)
    case failure
    case ended

    static func decode(_ body: Any) -> YouTubeBridgeEvent? {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else { return nil }
        switch type {
        case "surfaceReady":
            return .surfaceReady
        case "ready":
            return .ready
        case "playing":
            return .playing
        case "time":
            guard let seconds = (dict["sec"] as? NSNumber)?.doubleValue,
                  seconds.isFinite else { return nil }
            return .time(seconds)
        case "clipEnded":
            guard let rawNonce = dict["nonce"] as? String,
                  let nonce = UUID(uuidString: rawNonce) else { return nil }
            return .clipEnded(nonce)
        case "failure":
            return .failure
        case "ended":
            return .ended
        default:
            return nil
        }
    }
}

/// A seek request from SwiftUI → the embedded player. `nonce` forces SwiftUI
/// to treat repeated seeks to the same second as distinct (so updateUIView fires).
struct SeekRequest: Equatable {
    let seconds: Double
    let nonce: UUID
}

enum YouTubeSurfaceReuseAction: Equatable {
    case reuse
    case rebuild
}

struct YouTubeSurfaceReuseState: Equatable {
    private var currentKey: String?
    private var isActive = false

    mutating func action(for key: String) -> YouTubeSurfaceReuseAction {
        guard isActive, currentKey == key else {
            isActive = true
            currentKey = key
            return .rebuild
        }
        return .reuse
    }

    func pause() -> Bool {
        isActive
    }

    @discardableResult
    mutating func deactivate() -> Bool {
        guard isActive else { return false }
        isActive = false
        currentKey = nil
        return true
    }
}

enum YouTubeRestorePolicy {
    /// Defensive ceiling for corrupt legacy values before they cross the
    /// Swift/JavaScript boundary. Real Library videos are capped far below it.
    static let maximumSeconds: Double = 7 * 24 * 60 * 60

    static func target(savedSeconds: Double, durationSeconds: Double?) -> Double {
        guard savedSeconds.isFinite, savedSeconds >= 0 else { return 0 }
        let saved = min(savedSeconds, maximumSeconds)
        guard let durationSeconds,
              durationSeconds.isFinite,
              durationSeconds > 0 else { return saved }
        return min(saved, max(0, durationSeconds - 0.25))
    }
}

struct YouTubeBridgeHandoffSnapshot: Equatable {
    let surfaceReady: Bool
    let playerReady: Bool
    let queuedEvents: [YouTubeBridgeEvent]
}

/// Keeps readiness and non-idempotent events alive during the tiny interval
/// between dismantling one SwiftUI container and binding the next one.
struct YouTubeBridgeHandoffState: Equatable {
    private var surfaceReady = false
    private var playerReady = false
    private var failed = false
    private var queuedEvents: [YouTubeBridgeEvent] = []

    mutating func record(
        _ event: YouTubeBridgeEvent,
        hasConsumer: Bool
    ) -> [YouTubeBridgeEvent] {
        if failed {
            switch event {
            case .surfaceReady, .ready:
                return []
            default:
                break
            }
        }
        switch event {
        case .surfaceReady:
            surfaceReady = true
        case .ready:
            surfaceReady = true
            playerReady = true
        case .failure:
            failed = true
        default:
            break
        }

        guard !hasConsumer else { return [event] }
        switch event {
        case .playing, .clipEnded, .ended:
            queuedEvents.append(event)
            if queuedEvents.count > 8 {
                queuedEvents.removeFirst(queuedEvents.count - 8)
            }
        case .surfaceReady, .ready, .time, .failure:
            break
        }
        return []
    }

    mutating func bind() -> YouTubeBridgeHandoffSnapshot {
        var events = queuedEvents
        if failed, !events.contains(.failure) {
            events.append(.failure)
        }
        let snapshot = YouTubeBridgeHandoffSnapshot(
            surfaceReady: surfaceReady,
            playerReady: playerReady && !failed,
            queuedEvents: events
        )
        queuedEvents.removeAll(keepingCapacity: true)
        return snapshot
    }
}

/// Installed once for the lifetime of a WKWebView. The active SwiftUI
/// coordinator may change across rotation, but JavaScript never loses its
/// `iosBridge` message target.
final class YouTubeBridgeProxy: NSObject, WKScriptMessageHandler {
    private weak var coordinator: YouTubeEmbedView.Coordinator?
    private var handoffState = YouTubeBridgeHandoffState()

    func bind(_ coordinator: YouTubeEmbedView.Coordinator) {
        self.coordinator = coordinator
        let snapshot = handoffState.bind()
        coordinator.adoptReusableSurface(
            surfaceReady: snapshot.surfaceReady,
            playerReady: snapshot.playerReady
        )
        snapshot.queuedEvents.forEach { coordinator.receive($0) }
    }

    func unbind(_ coordinator: YouTubeEmbedView.Coordinator) {
        guard self.coordinator === coordinator else { return }
        self.coordinator = nil
    }

    func deactivate() {
        coordinator = nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "iosBridge",
              let event = YouTubeBridgeEvent.decode(message.body) else { return }
        for eventToDeliver in handoffState.record(
            event,
            hasConsumer: coordinator != nil
        ) {
            coordinator?.receive(eventToDeliver)
        }
    }
}

/// SwiftUI owns a fresh lightweight container per representable lifecycle;
/// the reusable WKWebView is moved between containers without being destroyed.
final class YouTubeWebViewContainer: UIView {
    private(set) weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        guard self.webView !== webView || webView.superview !== self else { return }
        self.webView?.removeFromSuperview()
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.webView = webView
    }

    func detach() {
        if webView?.superview === self {
            webView?.removeFromSuperview()
        }
        webView = nil
    }
}

/// Embeds a YouTube video via the official IFrame Player API in a WKWebView.
/// Bridge: Swift→JS `player.seekTo`; JS→Swift current time every 250ms via
/// `window.webkit.messageHandlers.iosBridge.postMessage`.
struct YouTubeEmbedView: UIViewRepresentable {
    let videoId: String
    var seek: SeekRequest?
    /// Called once when the IFrame player has loaded + is ready to play.
    /// Drives the SwiftUI loading overlay (the iframe API + first frame can
    /// take several seconds, especially over a VPN).
    var onReady: () -> Void
    /// Called ~4x/sec with the player's current time (seconds).
    var onTime: (Double) -> Void
    /// If set, the player starts at this timestamp (seconds). Default nil = no start offset.
    /// Pass this for corpus phrase instances that have a `timestampSec`; omit for Library callers.
    var startSeconds: Double? = nil
    /// Library resume position. Unlike an explicit seek, restoration never starts playback.
    var resumeSeconds: Double? = nil
    /// Optional bounded-playback command shared by cue-driven consumers.
    var clipCommand: YouTubeClipPlaybackCommand? = nil
    /// Full active clip state to replay when this representable gets a new coordinator.
    var replaySnapshot: YouTubeClipPlaybackCommand? = nil
    /// Called when the IFrame player reaches the active clip boundary.
    var onClipEnded: (UUID) -> Void = { _ in }
    /// Called when the IFrame player reports a playback error.
    var onFailure: () -> Void = {}
    /// Called only when the IFrame player explicitly reaches its ended state.
    var onEnded: () -> Void = {}
    /// Called whenever playback actually enters the playing state.
    var onPlaying: () -> Void = {}
    /// Clears the parent-owned command only after JavaScript received it.
    var onSeekConsumed: (UUID) -> Void = { _ in }
    /// Library detail supplies one shared surface so portrait/landscape layout
    /// changes reattach the existing WKWebView instead of restarting YouTube.
    var reusableSurface: YouTubeWebViewSurface? = nil
    /// A new playback generation intentionally creates a fresh WKWebView.
    var surfaceKey: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onReady: onReady,
            onTime: onTime,
            onClipEnded: onClipEnded,
            onFailure: onFailure,
            onEnded: onEnded,
            onPlaying: onPlaying,
            onSeekConsumed: onSeekConsumed
        )
    }

    func makeUIView(context: Context) -> YouTubeWebViewContainer {
        let container = YouTubeWebViewContainer()
        let html = Self.html(
            videoId: videoId,
            startSeconds: startSeconds,
            resumeSeconds: resumeSeconds
        )
        if let reusableSurface, let surfaceKey {
            let webView = reusableSurface.acquire(
                key: surfaceKey,
                coordinator: context.coordinator,
                html: html
            )
            container.attach(webView)
            return container
        }

        let bridgeProxy = YouTubeBridgeProxy()
        context.coordinator.bridgeProxy = bridgeProxy
        bridgeProxy.bind(context.coordinator)
        let webView = Self.makeWebView(bridgeProxy: bridgeProxy)
        context.coordinator.webView = webView
        webView.loadHTMLString(
            html,
            baseURL: URL(string: "https://www.youtube-nocookie.com")
        )
        container.attach(webView)
        return container
    }

    fileprivate static func makeWebView(bridgeProxy: YouTubeBridgeProxy) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(bridgeProxy, name: "iosBridge")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        return webView
    }

    func updateUIView(_ container: YouTubeWebViewContainer, context: Context) {
        if let seek {
            context.coordinator.requestExplicitSeek(seek)
        }

        if context.coordinator.isFirstClipUpdate {
            context.coordinator.isFirstClipUpdate = false
            context.coordinator.lastObservedClipCommandNonce = clipCommand?.nonce
            if let replaySnapshot {
                for commandToDeliver in context.coordinator.clipDeliveryState.queue(replaySnapshot) {
                    context.coordinator.deliverClipCommand(commandToDeliver)
                }
            }
        } else if let clipCommand,
                  clipCommand.nonce != context.coordinator.lastObservedClipCommandNonce {
            context.coordinator.lastObservedClipCommandNonce = clipCommand.nonce
            for commandToDeliver in context.coordinator.clipDeliveryState.queue(clipCommand) {
                context.coordinator.deliverClipCommand(commandToDeliver)
            }
        }
    }

    static func dismantleUIView(
        _ container: YouTubeWebViewContainer,
        coordinator: Coordinator
    ) {
        if let reusableSurface = coordinator.reusableSurface {
            reusableSurface.release(coordinator: coordinator)
        } else {
            coordinator.webView?.configuration.userContentController.removeScriptMessageHandler(
                forName: "iosBridge"
            )
            coordinator.bridgeProxy?.unbind(coordinator)
        }
        container.detach()
        coordinator.webView = nil
        coordinator.bridgeProxy = nil
    }

    final class Coordinator: NSObject {
        let onReady: () -> Void
        let onTime: (Double) -> Void
        let onClipEnded: (UUID) -> Void
        let onFailure: () -> Void
        let onEnded: () -> Void
        let onPlaying: () -> Void
        let onSeekConsumed: (UUID) -> Void
        weak var webView: WKWebView?
        weak var reusableSurface: YouTubeWebViewSurface?
        var bridgeProxy: YouTubeBridgeProxy?
        private var lastSeek: SeekRequest?
        private var seekDeliveryState = PlayerSeekDeliveryState()
        var lastClipCommand: YouTubeClipPlaybackCommand?
        var clipDeliveryState = YouTubeClipCommandDeliveryState()
        var isFirstClipUpdate = true
        var lastObservedClipCommandNonce: UUID?
        private var didSignalReady = false
        init(
            onReady: @escaping () -> Void,
            onTime: @escaping (Double) -> Void,
            onClipEnded: @escaping (UUID) -> Void,
            onFailure: @escaping () -> Void,
            onEnded: @escaping () -> Void,
            onPlaying: @escaping () -> Void,
            onSeekConsumed: @escaping (UUID) -> Void
        ) {
            self.onReady = onReady
            self.onTime = onTime
            self.onClipEnded = onClipEnded
            self.onFailure = onFailure
            self.onEnded = onEnded
            self.onPlaying = onPlaying
            self.onSeekConsumed = onSeekConsumed
        }

        func receive(_ event: YouTubeBridgeEvent) {
            switch event {
            case .surfaceReady:
                if let request = seekDeliveryState.markReady() {
                    deliverExplicitSeek(request)
                }
            case .ready:
                if !didSignalReady {
                    didSignalReady = true
                    for commandToDeliver in clipDeliveryState.markReady() {
                        deliverClipCommand(commandToDeliver)
                    }
                    onReady()
                }
            case .time(let seconds):
                onTime(seconds)
            case .clipEnded(let nonce):
                onClipEnded(nonce)
            case .failure:
                onFailure()
            case .ended:
                onEnded()
            case .playing:
                onPlaying()
            }
        }

        func adoptReusableSurface(surfaceReady: Bool, playerReady: Bool) {
            if surfaceReady,
               let request = seekDeliveryState.markReady() {
                deliverExplicitSeek(request)
            }
            if playerReady, !didSignalReady {
                didSignalReady = true
                for commandToDeliver in clipDeliveryState.markReady() {
                    deliverClipCommand(commandToDeliver)
                }
                onReady()
            }
        }

        func requestExplicitSeek(_ request: SeekRequest) {
            guard request != lastSeek else { return }
            lastSeek = request
            guard let request = seekDeliveryState.queue(request) else { return }
            deliverExplicitSeek(request)
        }

        private func deliverExplicitSeek(_ request: SeekRequest) {
            let seconds = max(0, request.seconds)
            guard seconds.isFinite, let webView else { return }
            let acknowledge = onSeekConsumed
            let nonce = request.nonce
            webView.evaluateJavaScript("window.whatsubExplicitSeek(\(seconds))") { result, error in
                let resultWasTrue = (result as? NSNumber)?.boolValue == true
                guard PlayerSeekAcceptance.javascript(
                    resultWasTrue: resultWasTrue,
                    errorWasNil: error == nil
                ) else { return }
                DispatchQueue.main.async {
                    acknowledge(nonce)
                }
            }
        }

        func deliverClipCommand(_ command: YouTubeClipPlaybackCommand) {
            lastClipCommand = command
            guard let js = YouTubeEmbedView.clipJavaScript(for: command) else { return }
            webView?.evaluateJavaScript(js)
        }
    }

    static func clipJavaScript(for command: YouTubeClipPlaybackCommand) -> String? {
        switch command.kind {
        case .play:
            guard let start = command.start,
                  let end = command.end,
                  let rate = command.rate,
                  start.isFinite,
                  end.isFinite,
                  rate.isFinite else { return nil }
            let safeStart = max(0, start)
            guard end > safeStart else { return nil }
            let safeRate = min(max(rate, 0.25), 2.0)
            return """
            (function() {
              if (!window.player) { return; }
              var requestedRate = \(safeRate);
              var rates = window.player.getAvailablePlaybackRates ? window.player.getAvailablePlaybackRates() : [];
              var closestRate = requestedRate;
              if (rates.length) {
                closestRate = rates.reduce(function(closest, candidate) {
                  return Math.abs(candidate - requestedRate) < Math.abs(closest - requestedRate) ? candidate : closest;
                }, rates[0]);
              }
              if (window.player.setPlaybackRate) { window.player.setPlaybackRate(closestRate); }
              window.whatsubClipEnd = \(end);
              window.whatsubClipNonce = "\(command.nonce.uuidString)";
              if (window.player.seekTo) { window.player.seekTo(\(safeStart), true); }
              if (window.player.playVideo) { window.player.playVideo(); }
            })();
            """
        case .setRate:
            guard let rate = command.rate, rate.isFinite else { return nil }
            let safeRate = min(max(rate, 0.25), 2.0)
            return """
            (function() {
              if (!window.player || !window.player.setPlaybackRate) { return; }
              var requestedRate = \(safeRate);
              var rates = window.player.getAvailablePlaybackRates ? window.player.getAvailablePlaybackRates() : [];
              var closestRate = requestedRate;
              if (rates.length) {
                closestRate = rates.reduce(function(closest, candidate) {
                  return Math.abs(candidate - requestedRate) < Math.abs(closest - requestedRate) ? candidate : closest;
                }, rates[0]);
              }
              window.player.setPlaybackRate(closestRate);
            })();
            """
        case .stop:
            return """
            (function() {
              window.whatsubClipEnd = null;
              window.whatsubClipNonce = null;
              if (window.player && window.player.pauseVideo) { window.player.pauseVideo(); }
            })();
            """
        }
    }

    static func html(
        videoId rawVideoId: String,
        startSeconds: Double?,
        resumeSeconds: Double? = nil
    ) -> String {
        // Defense-in-depth: only a real YouTube id shape ([A-Za-z0-9_-]{11})
        // may be interpolated into the inline <script>. A hostile/malformed id
        // (e.g. one containing a quote or `</script>`) would otherwise break
        // out of the JS string literal and run arbitrary script in this
        // youtube-nocookie.com-origin webview, which also exposes the
        // `iosBridge` message handler. Anything that isn't a clean id collapses
        // to empty so the player just no-ops instead of executing it. The
        // backend independently sanitizes `source.youtubeId` on /contribute.
        let videoId = VideoSource.isLikelyYouTubeId(rawVideoId) ? rawVideoId : ""
        let startVar: String
        if let startSeconds, startSeconds.isFinite, startSeconds >= 0 {
            startVar = ", start: \(YouTubeRestorePolicy.target(savedSeconds: startSeconds, durationSeconds: nil))"
        } else {
            startVar = ""
        }
        let resumeScript: String
        if let resumeSeconds, resumeSeconds.isFinite, resumeSeconds >= 0 {
            let requestedTarget = YouTubeRestorePolicy.target(
                savedSeconds: resumeSeconds,
                durationSeconds: nil
            )
            resumeScript = """
                  var requestedRestoreTarget = \(requestedTarget);
                  var duration = window.player.getDuration ? window.player.getDuration() : NaN;
                  var restoreTarget = (Number.isFinite(duration) && duration > 0)
                    ? Math.min(requestedRestoreTarget, Math.max(0, duration - 0.25))
                    : requestedRestoreTarget;
                  var restoreRevision = ++window.whatsubRestoreRevision;
                  var restoreAttempts = 0;
                  window.player.seekTo(restoreTarget, true);
                  if (window.player.pauseVideo) { window.player.pauseVideo(); }
                  function confirmRestore() {
                    if (restoreRevision !== window.whatsubRestoreRevision) { return; }
                    restoreAttempts += 1;
                    var currentTime = window.player.getCurrentTime();
                    if (Math.abs(currentTime - restoreTarget) <= 2 || restoreAttempts >= 40) {
                      if (window.player.pauseVideo) { window.player.pauseVideo(); }
                      window.whatsubSignalReady();
                    } else {
                      setTimeout(confirmRestore, 100);
                    }
                  }
                  setTimeout(confirmRestore, 100);
            """
        } else {
            resumeScript = "                  window.whatsubSignalReady();"
        }
        return """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;background:#000;height:100%;overflow:hidden}#player{width:100%;height:100%}</style></head>
        <body><div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          window.player = null;
          window.whatsubClipEnd = null;
          window.whatsubClipNonce = null;
          window.whatsubRestoreRevision = 0;
          window.whatsubDidSignalReady = false;
          window.whatsubTimeInterval = null;
          window.whatsubStartTimeUpdates = function() {
            if (window.whatsubTimeInterval !== null) { return; }
            window.whatsubTimeInterval = setInterval(function() {
              if (window.player && window.player.getCurrentTime) {
                try {
                  var currentTime = window.player.getCurrentTime();
                  if (window.whatsubClipEnd !== null && currentTime >= window.whatsubClipEnd) {
                    if (window.player.pauseVideo) { window.player.pauseVideo(); }
                    var clipNonce = window.whatsubClipNonce;
                    window.whatsubClipEnd = null;
                    window.whatsubClipNonce = null;
                    if (clipNonce !== null) {
                      window.webkit.messageHandlers.iosBridge.postMessage(
                        { type: 'clipEnded', nonce: clipNonce });
                    }
                  }
                  window.webkit.messageHandlers.iosBridge.postMessage(
                    { type: 'time', sec: currentTime });
                } catch (e) {}
              }
            }, 250);
          };
          window.whatsubSignalReady = function() {
            if (window.whatsubDidSignalReady) { return; }
            window.whatsubDidSignalReady = true;
            try { window.webkit.messageHandlers.iosBridge.postMessage({ type: 'ready' }); } catch (e) {}
            window.whatsubStartTimeUpdates();
          };
          window.whatsubExplicitSeek = function(seconds) {
            window.whatsubRestoreRevision += 1;
            if (!window.player || !window.player.seekTo || !Number.isFinite(seconds)) { return false; }
            window.player.seekTo(Math.max(0, seconds), true);
            if (window.player.playVideo) { window.player.playVideo(); }
            window.whatsubSignalReady();
            return true;
          };
          function onYouTubeIframeAPIReady() {
            window.player = new YT.Player('player', {
              videoId: '\(videoId)',
              host: 'https://www.youtube-nocookie.com',
              playerVars: { playsinline: 1, modestbranding: 1, rel: 0\(startVar) },
              events: {
                onReady: function() {
                  try { window.webkit.messageHandlers.iosBridge.postMessage({ type: 'surfaceReady' }); } catch (e) {}
        \(resumeScript)
                },
                onStateChange: function(event) {
                  if (event.data === YT.PlayerState.PLAYING) {
                    window.whatsubRestoreRevision += 1;
                    try { window.webkit.messageHandlers.iosBridge.postMessage({ type: 'playing' }); } catch (e) {}
                    window.whatsubSignalReady();
                  }
                  if (event.data === YT.PlayerState.ENDED) {
                    try { window.webkit.messageHandlers.iosBridge.postMessage({ type: 'ended' }); } catch (e) {}
                  }
                },
                onError: function() {
                  window.whatsubRestoreRevision += 1;
                  try { window.webkit.messageHandlers.iosBridge.postMessage({ type: 'failure' }); } catch (e) {}
                }
              }
            });
          }
        </script></body></html>
        """
    }
}

/// Owns the Library detail YouTube web view independently of SwiftUI's
/// portrait/landscape branches. Rebinding only swaps the message coordinator;
/// the iframe, playback state, and timer remain alive for the same generation.
final class YouTubeWebViewSurface: ObservableObject {
    private var reuseState = YouTubeSurfaceReuseState()
    private var webView: WKWebView?
    private var bridgeProxy: YouTubeBridgeProxy?

    func acquire(
        key: String,
        coordinator: YouTubeEmbedView.Coordinator,
        html: String
    ) -> WKWebView {
        let action = reuseState.action(for: key)
        let target: WKWebView

        if action == .rebuild || webView == nil {
            if let oldWebView = webView {
                dispose(oldWebView)
            }
            bridgeProxy?.deactivate()
            let proxy = YouTubeBridgeProxy()
            bridgeProxy = proxy
            target = YouTubeEmbedView.makeWebView(bridgeProxy: proxy)
            webView = target
            bind(coordinator, webView: target)
            target.loadHTMLString(
                html,
                baseURL: URL(string: "https://www.youtube-nocookie.com")
            )
        } else {
            target = webView!
            bind(coordinator, webView: target)
        }
        return target
    }

    func release(coordinator: YouTubeEmbedView.Coordinator) {
        bridgeProxy?.unbind(coordinator)
    }

    /// Temporary visibility loss (tab switch/navigation cover) should stop
    /// audio without destroying the iframe needed when the view returns.
    func pause() {
        guard reuseState.pause(), let webView else { return }
        webView.evaluateJavaScript("""
        (function() {
          if (window.player && window.player.pauseVideo) { window.player.pauseVideo(); }
        })()
        """)
    }

    /// Permanently leaves the current playback path. Rotation deliberately
    /// uses `release` instead so the iframe and its playback position survive.
    func deactivate() {
        guard reuseState.deactivate() else { return }
        bridgeProxy?.deactivate()
        bridgeProxy = nil
        if let webView {
            dispose(webView)
            self.webView = nil
        }
    }

    private func bind(
        _ coordinator: YouTubeEmbedView.Coordinator,
        webView: WKWebView
    ) {
        coordinator.reusableSurface = self
        coordinator.bridgeProxy = bridgeProxy
        coordinator.webView = webView
        bridgeProxy?.bind(coordinator)
    }

    private func dispose(_ webView: WKWebView) {
        webView.evaluateJavaScript("""
        (function() {
          if (window.player && window.player.pauseVideo) { window.player.pauseVideo(); }
          if (window.player && window.player.destroy) { window.player.destroy(); }
        })()
        """)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "iosBridge"
        )
        webView.stopLoading()
        // Navigating away tears down the iframe even if the pause/destroy
        // evaluation above is cancelled by a concurrent source transition.
        webView.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
        webView.removeFromSuperview()
    }
}
