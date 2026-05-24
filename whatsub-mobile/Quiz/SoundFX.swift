import AVFoundation
import AudioToolbox
import UIKit

/// Quiz feedback on a correct answer: a success haptic + a short chime.
///
/// The chime plays via `AVAudioPlayer` on a `.playback` session (with
/// `.mixWithOthers`) so it is audible even when the ringer/silent switch is ON
/// — like games do — without stopping any background audio. (A plain
/// `AudioServicesPlaySystemSound` respects the silent switch, so it was
/// inaudible for users with mute on; that's only the fallback now.)
enum SoundFX {
    /// Retained so the player isn't deallocated before it finishes playing.
    private static var player: AVAudioPlayer?

    static func correct() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard let url = Bundle.main.url(forResource: "correct", withExtension: "wav") else {
            AudioServicesPlaySystemSound(1057) // fallback if the asset is missing
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            p.prepareToPlay()
            p.play()
        } catch {
            AudioServicesPlaySystemSound(1057) // fallback on any audio error
        }
    }
}
