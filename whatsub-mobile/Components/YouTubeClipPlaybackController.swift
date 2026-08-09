import Combine
import Foundation

struct YouTubeClipPlaybackCommand: Equatable {
    enum Kind: Equatable {
        case play
        case setRate
        case stop
    }

    let kind: Kind
    let start: Double?
    let end: Double?
    let rate: Double?
    let nonce: UUID

    static func play(start: Double, end: Double, rate: Double) -> Self {
        Self(kind: .play, start: start, end: end, rate: rate, nonce: UUID())
    }

    static func setRate(_ rate: Double) -> Self {
        Self(kind: .setRate, start: nil, end: nil, rate: rate, nonce: UUID())
    }

    static func stop() -> Self {
        Self(kind: .stop, start: nil, end: nil, rate: nil, nonce: UUID())
    }
}

struct YouTubeClipCommandDeliveryState {
    private var isReady = false
    private var pendingCommand: YouTubeClipPlaybackCommand?
    private var lastDeliveredCommand: YouTubeClipPlaybackCommand?

    mutating func queue(_ command: YouTubeClipPlaybackCommand) -> YouTubeClipPlaybackCommand? {
        guard command != lastDeliveredCommand else { return nil }
        guard isReady else {
            pendingCommand = command
            return nil
        }
        return deliver(command)
    }

    mutating func markReady() -> YouTubeClipPlaybackCommand? {
        isReady = true
        guard let pendingCommand else { return nil }
        self.pendingCommand = nil
        return deliver(pendingCommand)
    }

    private mutating func deliver(_ command: YouTubeClipPlaybackCommand) -> YouTubeClipPlaybackCommand? {
        guard command != lastDeliveredCommand else { return nil }
        lastDeliveredCommand = command
        return command
    }
}

@MainActor
final class YouTubeClipPlaybackController: ObservableObject {
    @Published private(set) var command: YouTubeClipPlaybackCommand?
    @Published private(set) var isPlaying = false

    @discardableResult
    func play(start: Double, end: Double, rate: Double) -> Bool {
        guard start.isFinite, end.isFinite, rate.isFinite else { return false }

        let safeStart = max(0, start)
        guard end > safeStart else { return false }

        let safeRate = min(max(rate, 0.25), 2.0)
        command = .play(start: safeStart, end: end, rate: safeRate)
        isPlaying = true
        return true
    }

    func setRate(_ rate: Double) {
        guard isPlaying, rate.isFinite else { return }
        command = .setRate(min(max(rate, 0.25), 2.0))
    }

    func stop() {
        command = .stop()
        isPlaying = false
    }

    func clipEnded() {
        isPlaying = false
    }
}
