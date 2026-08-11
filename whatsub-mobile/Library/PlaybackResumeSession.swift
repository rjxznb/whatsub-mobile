import Foundation

enum PlaybackPersistenceDecision: Equatable {
    case none
    case save(Double)
    case clear
}

struct PlaybackResumeSession: Equatable {
    private(set) var generation = 0
    private(set) var resumePosition: Double?

    private var latestPosition: Double?
    private var lastPersistedPosition: Double?
    private var lastPersistedAt: Date?
    private var readyGeneration: Int?
    private var isRestoring = false
    private var isCompletionSuppressed = false

    init(restoredPosition: Double?) {
        let restored = Self.validPosition(restoredPosition)
        resumePosition = restored
        latestPosition = restored
        lastPersistedPosition = restored
    }

    mutating func beginReload() -> Int {
        generation += 1
        readyGeneration = nil
        resumePosition = latestPosition
        isRestoring = resumePosition != nil
        return generation
    }

    mutating func markReady(generation: Int) {
        guard generation == self.generation else { return }
        readyGeneration = generation
        isRestoring = false
    }

    func shouldAcceptTimeout(generation: Int) -> Bool {
        generation == self.generation && readyGeneration != generation
    }

    func isCurrent(generation: Int) -> Bool {
        generation == self.generation
    }

    mutating func receiveTime(
        _ position: Double,
        now: Date = Date()
    ) -> PlaybackPersistenceDecision {
        guard let position = Self.validPosition(position) else { return .none }
        guard !isRestoring, !isCompletionSuppressed else { return .none }

        latestPosition = position
        resumePosition = position
        if lastPersistedAt != nil,
           let lastPersistedPosition,
           floor(lastPersistedPosition) == floor(position) {
            return .none
        }
        guard lastPersistedAt == nil || now.timeIntervalSince(lastPersistedAt!) >= 5 else {
            return .none
        }
        lastPersistedAt = now
        lastPersistedPosition = position
        return .save(position)
    }

    mutating func markExplicitSeek(
        _ position: Double,
        now: Date = Date()
    ) -> PlaybackPersistenceDecision {
        guard let position = Self.validPosition(position) else { return .none }
        isRestoring = false
        isCompletionSuppressed = false
        latestPosition = position
        resumePosition = position
        lastPersistedAt = now
        lastPersistedPosition = position
        return .save(position)
    }

    mutating func markPlaying() {
        guard isRestoring || isCompletionSuppressed else { return }
        isRestoring = false
        isCompletionSuppressed = false
        lastPersistedAt = nil
        lastPersistedPosition = nil
    }

    mutating func markEnded() -> PlaybackPersistenceDecision {
        isCompletionSuppressed = true
        isRestoring = false
        latestPosition = nil
        resumePosition = nil
        lastPersistedAt = nil
        lastPersistedPosition = nil
        return .clear
    }

    mutating func forceFlushDecision(
        now: Date = Date()
    ) -> PlaybackPersistenceDecision {
        guard !isCompletionSuppressed,
              let latestPosition,
              latestPosition != lastPersistedPosition else { return .none }
        lastPersistedAt = now
        lastPersistedPosition = latestPosition
        return .save(latestPosition)
    }

    private static func validPosition(_ position: Double?) -> Double? {
        guard let position, position.isFinite, position >= 0 else { return nil }
        return position
    }
}
