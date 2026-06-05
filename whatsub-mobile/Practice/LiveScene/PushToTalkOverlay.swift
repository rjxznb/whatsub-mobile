import SwiftUI
import UIKit

/// UIKit-backed push-to-talk hit-area. **Layered on top of VoiceOrbView**
/// to capture touch-down / touch-up reliably — SwiftUI's `DragGesture` /
/// `LongPressGesture` / `simultaneousGesture` all got the gesture
/// silently cancelled mid-press inside LiveSceneView (debug confirmed:
/// only 1 `onChanged` event fired then nothing on release, until a
/// fresh tap rebooted the cycle). The 4 SwiftUI attempts:
///   • d7e501a: inline DragGesture → captured stale `isRecording`
///   • 0b5e6ca: read `vm.phase` inside closure → still inline → still bad
///   • 41a97f0: computed property gesture + @State latch → still bad
///   • fe9c470: removed ScrollView ancestor → still bad
///
/// The root cause is that SwiftUI's gesture system in this view tree
/// just decides to drop our gesture for reasons we don't control. UIKit
/// `UILongPressGestureRecognizer` with `minimumPressDuration = 0` and
/// `allowableMovement = .greatestFiniteMagnitude` doesn't have that
/// problem — it owns the touch outright once it begins, and fires
/// `.ended` / `.cancelled` deterministically on release.
///
/// Layout: this view renders fully-transparent + fills the parent.
/// Layer it as a `ZStack` overlay on the VoiceOrbView with
/// `.allowsHitTesting(true)` so it catches taps that would otherwise
/// go to the orb. The visual orb is hit-tested through THIS layer.
///
/// 2026-06-05 (5th attempt at the orb gesture, finally past SwiftUI).
struct PushToTalkOverlay: UIViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let recogniser = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        // minimumPressDuration = 0 → fire .began immediately on touch-down
        // (push-to-talk has no "must hold for N seconds" requirement).
        recogniser.minimumPressDuration = 0
        // allowableMovement = .infinity → finger wiggle during a hold
        // does NOT cancel the gesture. Critical: this was the silent
        // killer on SwiftUI's DragGesture too — even a few pixels of
        // tremor caused the parent scroll/nav recogniser to "steal" the
        // touch and cancel ours.
        recogniser.allowableMovement = .greatestFiniteMagnitude
        // cancelsTouchesInView = false → don't swallow touches from
        // sibling SwiftUI elements (none here today, but defensive).
        recogniser.cancelsTouchesInView = false
        // delaysTouchesBegan = false → fire .began on the very first
        // touch event, not after a system delay.
        recogniser.delaysTouchesBegan = false
        // Mark as our own so the delegate can recognise alongside
        // anything else (e.g. ScrollView pan).
        recogniser.delegate = context.coordinator

        view.addGestureRecognizer(recogniser)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // Closures change every parent render (they capture vm + State);
        // re-store the latest pair on the coordinator so the gesture
        // callback fires the up-to-date handlers.
        context.coordinator.onPress = onPress
        context.coordinator.onRelease = onRelease
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress, onRelease: onRelease)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPress: () -> Void
        var onRelease: () -> Void

        init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
            self.onPress = onPress
            self.onRelease = onRelease
        }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                onPress()
            case .ended, .cancelled, .failed:
                onRelease()
            default:
                break
            }
        }

        // Recognise simultaneously with everything else — we don't want
        // a parent scroll/nav recogniser to fight us.
        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
