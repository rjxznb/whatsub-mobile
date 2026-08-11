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
    private var completedTail: Double?
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
        return generation
    }

    mutating func markReady(generation: Int) {
        guard generation == self.generation else { return }
        readyGeneration = generation
    }

    func shouldAcceptTimeout(generation: Int) -> Bool {
        generation == self.generation && readyGeneration != generation
    }

    mutating func receiveTime(
        _ position: Double,
        now: Date = Date()
    ) -> PlaybackPersistenceDecision {
        guard let position = Self.validPosition(position) else { return .none }

        if isCompletionSuppressed {
            guard let completedTail,
                  position <= max(0, completedTail - 1) else { return .none }
            isCompletionSuppressed = false
            self.completedTail = nil
            lastPersistedAt = nil
            lastPersistedPosition = nil
        }

        latestPosition = position
        resumePosition = position
        guard lastPersistedAt == nil || now.timeIntervalSince(lastPersistedAt!) >= 5 else {
            return .none
        }
        lastPersistedAt = now
        lastPersistedPosition = position
        return .save(position)
    }

    mutating func markEnded() -> PlaybackPersistenceDecision {
        completedTail = latestPosition ?? resumePosition
        isCompletionSuppressed = true
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
