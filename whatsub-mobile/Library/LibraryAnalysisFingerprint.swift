import Foundation
import CryptoKit

enum LibraryAnalysisFingerprint {
    private struct Payload: Encodable {
        let subtitles: [Subtitle]
    }

    private struct Subtitle: Encodable {
        let endTime: Double
        let index: Int
        let text: String
        let time: Double
    }

    static func compute(title _: String, cues: [Cue]) -> String {
        let subtitles = cues.enumerated().map { offset, cue in
            Subtitle(
                endTime: cue.endTime,
                index: cue.index == 0 ? offset : cue.index,
                text: cue.text,
                time: cue.time
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(subtitles: subtitles)) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
