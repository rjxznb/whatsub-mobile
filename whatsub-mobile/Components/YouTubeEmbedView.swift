import SwiftUI
import WebKit

/// A seek request from SwiftUI → the embedded player. `nonce` forces SwiftUI
/// to treat repeated seeks to the same second as distinct (so updateUIView fires).
struct SeekRequest: Equatable {
    let seconds: Double
    let nonce: UUID
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
    /// Optional bounded-playback command shared by cue-driven consumers.
    var clipCommand: YouTubeClipPlaybackCommand? = nil
    /// Full active clip state to replay when this representable gets a new coordinator.
    var replaySnapshot: YouTubeClipPlaybackCommand? = nil
    /// Called when the IFrame player reaches the active clip boundary.
    var onClipEnded: (UUID) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onTime: onTime, onClipEnded: onClipEnded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "iosBridge")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.loadHTMLString(Self.html(videoId: videoId, startSeconds: startSeconds), baseURL: URL(string: "https://www.youtube-nocookie.com"))
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let seek, seek != context.coordinator.lastSeek {
            context.coordinator.lastSeek = seek
            let js = "if (window.player && window.player.seekTo) { window.player.seekTo(\(seek.seconds), true); window.player.playVideo(); }"
            webView.evaluateJavaScript(js)
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

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onReady: () -> Void
        let onTime: (Double) -> Void
        let onClipEnded: (UUID) -> Void
        weak var webView: WKWebView?
        var lastSeek: SeekRequest?
        var lastClipCommand: YouTubeClipPlaybackCommand?
        var clipDeliveryState = YouTubeClipCommandDeliveryState()
        var isFirstClipUpdate = true
        var lastObservedClipCommandNonce: UUID?
        private var didSignalReady = false
        init(
            onReady: @escaping () -> Void,
            onTime: @escaping (Double) -> Void,
            onClipEnded: @escaping (UUID) -> Void
        ) {
            self.onReady = onReady
            self.onTime = onTime
            self.onClipEnded = onClipEnded
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "iosBridge",
                  let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }
            switch type {
            case "ready":
                if !didSignalReady {
                    didSignalReady = true
                    for commandToDeliver in clipDeliveryState.markReady() {
                        deliverClipCommand(commandToDeliver)
                    }
                    onReady()
                }
            case "time":
                if let sec = dict["sec"] as? Double { onTime(sec) }
            case "clipEnded":
                guard let rawNonce = dict["nonce"] as? String,
                      let nonce = UUID(uuidString: rawNonce) else { return }
                onClipEnded(nonce)
            default:
                break
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

    static func html(videoId rawVideoId: String, startSeconds: Double?) -> String {
        // Defense-in-depth: only a real YouTube id shape ([A-Za-z0-9_-]{11})
        // may be interpolated into the inline <script>. A hostile/malformed id
        // (e.g. one containing a quote or `</script>`) would otherwise break
        // out of the JS string literal and run arbitrary script in this
        // youtube-nocookie.com-origin webview, which also exposes the
        // `iosBridge` message handler. Anything that isn't a clean id collapses
        // to empty so the player just no-ops instead of executing it. The
        // backend independently sanitizes `source.youtubeId` on /contribute.
        let videoId = VideoSource.isLikelyYouTubeId(rawVideoId) ? rawVideoId : ""
        let startVar = startSeconds.map { ", start: \(Int($0))" } ?? ""
        return """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;background:#000;height:100%;overflow:hidden}#player{width:100%;height:100%}</style></head>
        <body><div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          window.player = null;
          window.whatsubClipEnd = null;
          window.whatsubClipNonce = null;
          function onYouTubeIframeAPIReady() {
            window.player = new YT.Player('player', {
              videoId: '\(videoId)',
              host: 'https://www.youtube-nocookie.com',
              playerVars: { playsinline: 1, modestbranding: 1, rel: 0\(startVar) },
              events: {
                onReady: function() {
                  try { window.webkit.messageHandlers.iosBridge.postMessage({ type: 'ready' }); } catch (e) {}
                  setInterval(function() {
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
                }
              }
            });
          }
        </script></body></html>
        """
    }
}
