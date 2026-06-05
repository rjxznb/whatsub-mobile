import SwiftUI
import UIKit

/// `UIControl`-based push-to-talk hit area. **8th** attempt at the
/// LiveScene orb gesture — all previous 7 attempts (incl. raw
/// `touchesBegan/Ended/Cancelled` overrides on a plain UIView in #7)
/// have had iOS silently swallow the release event. Debug logs confirmed
/// in `9693e41` that during the entire 4.6-second hold NOT ONE touch
/// event fired on our view between BEGAN and the user's eventual second
/// tap.
///
/// `UIControl` has its OWN target-action touch tracking system,
/// independent of `UIGestureRecognizer`. `UIButton`, `UISwitch`,
/// `UISlider` all use this — `.touchDown` fires at touch arrival,
/// `.touchUpInside`/`.touchUpOutside`/`.touchCancel`/`.touchDragExit`
/// fire on release. These are dispatched via `UIControl`'s own
/// `beginTracking/continueTracking/endTracking/cancelTracking`
/// machinery, which doesn't go through SwiftUI's gesture coordinator.
///
/// Also added comprehensive lifecycle logging via an `onLog` callback
/// so we can SEE if the UIView is being torn down mid-press (which
/// would explain why even raw touch overrides go silent).
///
/// 2026-06-05.
struct PushToTalkOverlay: UIViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void
    let onLog: ((String) -> Void)?

    init(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onLog: ((String) -> Void)? = nil
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onLog = onLog
    }

    func makeUIView(context: Context) -> PushToTalkControl {
        let control = PushToTalkControl()
        control.backgroundColor = .clear
        control.isUserInteractionEnabled = true
        // Make us greedy with touches — no sibling view in this view
        // hierarchy should fight us.
        control.isExclusiveTouch = true
        control.isMultipleTouchEnabled = false
        control.onPress = onPress
        control.onRelease = onRelease
        control.onLog = onLog
        return control
    }

    func updateUIView(_ control: PushToTalkControl, context: Context) {
        // Re-bind closures on each parent render so the latest captured
        // state is in effect.
        control.onPress = onPress
        control.onRelease = onRelease
        control.onLog = onLog
    }

    final class PushToTalkControl: UIControl {
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        var onLog: ((String) -> Void)?

        /// Single-tap haptic on press + release. Same UIImpactFeedbackGenerator
        /// pattern QuickChat uses. (LiveScene was previously missing any
        /// haptic feedback — user-reported 2026-06-05 "实景口语练习根本
        /// 没有震动".) NOT a continuous rumble — single thunks only,
        /// matching QuickChat's revised UX.
        private let pressHaptic = UIImpactFeedbackGenerator(style: .rigid)
        private let releaseHaptic = UIImpactFeedbackGenerator(style: .light)

        override init(frame: CGRect) {
            super.init(frame: frame)
            wire()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wire()
        }

        private func wire() {
            // No addTarget — we override beginTracking/endTracking/
            // cancelTracking directly. Build c549807's log showed UIC
            // touchUp firing only 55ms after start phase changed,
            // with NO RAW touchesEnded/Cancelled in between — that's
            // SOMETHING calling endTracking()/cancelTracking() on us
            // externally (suspected: audio session activation in
            // recorder.start() triggers a UI redraw that flips
            // UIControl's tracking state).
            //
            // Bypassing addTarget + driving onPress/onRelease from
            // begin/end/cancel-Tracking gives us:
            //   1. Logs showing WHICH callback was triggered.
            //   2. Independence from .touchUpInside/etc events that
            //      can be re-triggered by view layout changes.
        }

        // MARK: - UIControl tracking overrides (manual, no addTarget)

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            onLog?("UIC beginTracking")
            pressHaptic.impactOccurred(intensity: 1.0)
            onPress?()
            return true   // stay tracking
        }

        /// Always keep tracking — don't let UIControl auto-cancel the
        /// touch when the finger drags outside the control's bounds.
        /// Push-to-talk has no concept of "drag-cancelled" press; only
        /// physical release ends it.
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            onLog?("UIC endTracking")
            releaseHaptic.impactOccurred(intensity: 0.55)
            onRelease?()
            // NOT calling super — super.endTracking would fire
            // .touchUpInside/.touchUpOutside which we don't observe
            // and the default behaviour can also re-enter our
            // callbacks.
        }

        override func cancelTracking(with event: UIEvent?) {
            onLog?("UIC cancelTracking")
            // Skip the release haptic on cancellation — cancellation is
            // a "stolen by system" event, not a user release, so
            // simulating the release feedback would be misleading.
            onRelease?()
            // Same rationale as endTracking — skip super.
        }

        @objc private func handleDown() {
            onLog?("UIC touchDown")
            onPress?()
        }

        @objc private func handleUp() {
            onLog?("UIC touchUp/Cancel")
            onRelease?()
        }

        // MARK: - Belt + suspenders: also override raw touch methods.

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            onLog?("RAW touchesBegan")
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            onLog?("RAW touchesEnded")
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            onLog?("RAW touchesCancelled")
        }

        // MARK: - View lifecycle — confirms the view stays alive while
        // the user holds. If we see willMove(toSuperview: nil) mid-press
        // then SwiftUI is destroying the view and that's our culprit.

        override func willMove(toSuperview newSuperview: UIView?) {
            super.willMove(toSuperview: newSuperview)
            onLog?("LIFE willMove \(newSuperview == nil ? "→nil" : "→super")")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onLog?("LIFE didMove \(superview == nil ? "(detached)" : "(attached)")")
        }
    }
}
