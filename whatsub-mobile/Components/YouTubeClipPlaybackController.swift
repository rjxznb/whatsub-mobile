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
    private var pendingCommands: [YouTubeClipPlaybackCommand] = []
    private var deliveredNonces: Set<UUID> = []

    mutating func queue(_ command: YouTubeClipPlaybackCommand) -> [YouTubeClipPlaybackCommand] {
        guard !deliveredNonces.contains(command.nonce) else { return [] }
        if isReady {
            return deliver([command])
        }

        if command.kind == .stop {
            pendingCommands.removeAll()
            pendingCommands.append(command)
            return []
        }

        guard !pendingCommands.contains(where: { $0.nonce == command.nonce }) else { return [] }
        pendingCommands.append(command)
        return []
    }

    mutating func markReady() -> [YouTubeClipPlaybackCommand] {
        isReady = true
        let commands = pendingCommands
        pendingCommands.removeAll()
        return deliver(commands)
    }

    private mutating func deliver(
        _ commands: [YouTubeClipPlaybackCommand]
    ) -> [YouTubeClipPlaybackCommand] {
        var undelivered: [YouTubeClipPlaybackCommand] = []
        for command in commands where deliveredNonces.insert(command.nonce).inserted {
            undelivered.append(command)
        }
        return undelivered
    }
}

@MainActor
final class YouTubeClipPlaybackController: ObservableObject {
    @Published private(set) var command: YouTubeClipPlaybackCommand?
    @Published private(set) var isPlaying = false
    private var activeClip: YouTubeClipPlaybackCommand?

    var consumerRebuildReplaySnapshot: YouTubeClipPlaybackCommand? {
        activeClip
    }

    @discardableResult
    func play(start: Double, end: Double, rate: Double) -> Bool {
        guard start.isFinite, end.isFinite, rate.isFinite else { return false }

        let safeStart = max(0, start)
        guard end > safeStart else { return false }

        let safeRate = min(max(rate, 0.25), 2.0)
        let nextCommand = YouTubeClipPlaybackCommand.play(
            start: safeStart,
            end: end,
            rate: safeRate
        )
        command = nextCommand
        activeClip = nextCommand
        isPlaying = true
        return true
    }

    func setRate(_ rate: Double) {
        guard isPlaying, rate.isFinite, let activeClip else { return }
        let safeRate = min(max(rate, 0.25), 2.0)
        command = .setRate(safeRate)
        self.activeClip = YouTubeClipPlaybackCommand(
            kind: .play,
            start: activeClip.start,
            end: activeClip.end,
            rate: safeRate,
            nonce: activeClip.nonce
        )
    }

    func stop() {
        command = .stop()
        activeClip = nil
        isPlaying = false
    }

    func clipEnded(nonce: UUID) {
        guard activeClip?.nonce == nonce else { return }
        stop()
    }
}
