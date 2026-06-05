import SwiftUI
import UIKit

/// Raw-touch UIView wrapper for push-to-talk. **Bypasses every higher
/// abstraction layer in iOS** — no `UIGestureRecognizer`, no SwiftUI
/// `Button`, no `DragGesture`. Just `UIResponder`'s
/// `touchesBegan/Ended/Cancelled` overrides.
///
/// Why this is the final, can-not-fail attempt at the LiveScene orb
/// gesture (6 prior attempts all hit "release event silently swallowed
/// by SwiftUI's gesture machinery"):
///
/// iOS dispatches touch events to the first responder of the touch's
/// hit-test result. `touchesBegan` arrives in YOUR view. The OS then
/// **guarantees** that either `touchesEnded` OR `touchesCancelled` will
/// be sent to the same view before the touch sequence ends — no
/// gesture recognizer, scroll view, or framework can suppress these
/// callbacks. We handle both as "release" so the press/release pair
/// is always balanced.
///
/// Compare with the failed attempts:
///   • SwiftUI DragGesture / LongPressGesture: SwiftUI's gesture
///     coordinator can drop a gesture mid-stream without notification.
///   • SwiftUI Button + ButtonStyle: Button internally uses a tap
///     gesture; same dispatcher problem (the .isPressed transitions
///     stop firing during long holds for the same reason).
///   • UILongPressGestureRecognizer overlay: gesture recognizer state
///     can transition .began → .failed silently if another recognizer
///     claims the touch — even with `cancelsTouchesInView = false`.
///
/// `touchesBegan/Ended/Cancelled` are below all of that. The OS sends
/// them. We can't be silently bypassed.
///
/// Pairs with `.allowsHitTesting(false)` on the VoiceOrbView underneath
/// so the SwiftUI view doesn't even register for hit-testing → our
/// raw UIView is the unambiguous topmost hit target at the touch
/// location.
///
/// 2026-06-05 (attempt #7, finally below SwiftUI).
struct PushToTalkOverlay: UIViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> PushToTalkView {
        let view = PushToTalkView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.onPress = onPress
        view.onRelease = onRelease
        return view
    }

    func updateUIView(_ view: PushToTalkView, context: Context) {
        // Closures may capture fresh state on each parent render —
        // re-bind every update so the latest closure is fired.
        view.onPress = onPress
        view.onRelease = onRelease
    }

    /// Custom UIView with raw touch overrides. NOT private so the
    /// UIViewRepresentable's typed `makeUIView/updateUIView` signatures
    /// can refer to it.
    final class PushToTalkView: UIView {
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        /// Per-touch latch so we never fire onRelease twice for the
        /// same touch sequence (e.g. if both touchesEnded AND
        /// touchesCancelled somehow land for the same touch).
        private var touchActive: Bool = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            guard !touchActive else { return }
            touchActive = true
            onPress?()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            guard touchActive else { return }
            touchActive = false
            onRelease?()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            guard touchActive else { return }
            touchActive = false
            onRelease?()
        }
    }
}
