import SwiftUI
import WebKit

/// Pure passthrough SwiftUI host for a WKWebView that's owned by the
/// caller (created elsewhere, lifecycle managed elsewhere). Unlike a
/// regular WKWebView wrapper this view does NOT create the WebView in
/// `makeUIView` — it just mounts the externally-provided instance in the
/// view tree.
///
/// Use case: `CaptionExtractor` builds its own WKWebView so it can wire
/// the navigation delegate, user scripts, and message handlers in one
/// place, then hands it to `ImportView` so the view gets real
/// presentation (a window + non-zero frame + non-hidden). YouTube's
/// player needs view-tree presence to bypass the "off-screen player"
/// caption-suspension path, and SwiftUI is the only way to mount a UIView
/// into the active window from a SwiftUI view hierarchy.
///
/// Pair with `.opacity(0.001)` + `.allowsHitTesting(false)` at the call
/// site to keep the WebView invisible + non-interactive while satisfying
/// IntersectionObserver/visibility-state checks inside the page.
struct WKWebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
