import Foundation

enum PlaybackPersistenceDecision: Equatable {
    case none
    case save(Double)
    case clear
}

struct PlaybackResumeSession: Equatable {
    private static let completedTailTolerance: Double = 0.01

    private(set) var generation = 0
    private(set) var resumePosition: Double?

    private var latestPosition: Double?
    private var lastPersistedPosition: Double?
    private var lastPersistedAt: Date?
    private var readyGeneration: Int?
    private var isRestoring = false
    private var isCompletionSuppressed = false
    private var completedTailPosition: Double?

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
        guard !isRestoring else { return .none }

        if isCompletionSuppressed {
            guard let completedTailPosition,
                  position < completedTailPosition - Self.completedTailTolerance else {
                return .none
            }
            isCompletionSuppressed = false
            self.completedTailPosition = nil
            lastPersistedAt = nil
            lastPersistedPosition = nil
        }

        latestPosition = position
        resumePosition = position
        if let lastPersistedPosition,
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
        completedTailPosition = nil
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
        completedTailPosition = nil
        lastPersistedAt = nil
        lastPersistedPosition = nil
    }

    mutating func markEnded(at position: Double? = nil) -> PlaybackPersistenceDecision {
        completedTailPosition = Self.validPosition(position) ?? latestPosition ?? resumePosition
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
              lastPersistedPosition.map({ floor($0) }) != floor(latestPosition) else {
            return .none
        }
        lastPersistedAt = now
        lastPersistedPosition = latestPosition
        return .save(latestPosition)
    }

    private static func validPosition(_ position: Double?) -> Double? {
        guard let position, position.isFinite, position >= 0 else { return nil }
        return position
    }
}
