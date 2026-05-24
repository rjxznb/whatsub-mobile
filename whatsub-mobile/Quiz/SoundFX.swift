import AudioToolbox
import UIKit

/// Lightweight quiz feedback: a system sound (no bundled asset) + a success haptic.
enum SoundFX {
    static func correct() {
        AudioServicesPlaySystemSound(1057) // short positive system click
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
