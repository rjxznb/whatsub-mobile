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

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onTime: onTime) }

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
        guard let seek, seek != context.coordinator.lastSeek else { return }
        context.coordinator.lastSeek = seek
        let js = "if (window.player && window.player.seekTo) { window.player.seekTo(\(seek.seconds), true); window.player.playVideo(); }"
        webView.evaluateJavaScript(js)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onReady: () -> Void
        let onTime: (Double) -> Void
        weak var webView: WKWebView?
        var lastSeek: SeekRequest?
        private var didSignalReady = false
        init(onReady: @escaping () -> Void, onTime: @escaping (Double) -> Void) {
            self.onReady = onReady
            self.onTime = onTime
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "iosBridge",
                  let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }
            switch type {
            case "ready":
                if !didSignalReady { didSignalReady = true; onReady() }
            case "time":
                if let sec = dict["sec"] as? Double { onTime(sec) }
            default:
                break
            }
        }
    }

    private static func html(videoId: String, startSeconds: Double?) -> String {
        let startVar = startSeconds.map { ", start: \(Int($0))" } ?? ""
        return """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;background:#000;height:100%;overflow:hidden}#player{width:100%;height:100%}</style></head>
        <body><div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          window.player = null;
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
                        window.webkit.messageHandlers.iosBridge.postMessage(
                          { type: 'time', sec: window.player.getCurrentTime() });
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
