import Foundation

/// File-backed per-phrase production-mastery store. Mirror of
/// Quiz/QuizProgressStore.swift's "init loads from disk, mutation rewrites
/// atomically" pattern. Persists to Documents/production_progress.json by
/// default. Survives app kills. Local-only; no cloud sync in v1 (spec §3.2).
final class ProductionProgressStore {
    private let fileURL: URL
    private var phrases: [String: ProductionProgress]

    init(fileURL: URL = ProductionProgressStore.defaultURL) {
        self.fileURL = fileURL
        self.phrases = ProductionProgressStore.loadFrom(fileURL)
    }

    static var defaultURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("production_progress.json")
    }

    func progress(for phrase: String) -> ProductionProgress? { phrases[phrase] }
    func snapshot() -> [String: ProductionProgress] { phrases }

    /// Record one correct use. `at` is epoch seconds (Date().timeIntervalSince1970).
    /// Crossing the mastery threshold sets `masteredAt` (only the first crossing).
    func recordCorrect(phrase: String, at: Double) {
        var p = phrases[phrase] ?? ProductionProgress(phraseNormalized: phrase)
        p.usedCorrectCount += 1
        p.attemptCount += 1
        p.lastPracticedAt = at
        if p.masteredAt == nil, p.usedCorrectCount >= ProductionProgress.masteryThreshold {
            p.masteredAt = at
        }
        phrases[phrase] = p
        save()
    }

    /// Record one wrong attempt (the LLM said `attempted: true, correct: false`)
    /// or any tracked error. `note` becomes `lastErrorNote` for review.
    func recordWrong(phrase: String, note: String, at: Double) {
        var p = phrases[phrase] ?? ProductionProgress(phraseNormalized: phrase)
        p.attemptCount += 1
        p.lastErrorNote = note
        p.lastPracticedAt = at
        phrases[phrase] = p
        save()
    }

    /// True iff this phrase was mastered and the spaced-repetition window has
    /// elapsed since lastPracticedAt — so it should reenter the candidate pool.
    func isDueForRepetition(phrase: String, now: Double) -> Bool {
        guard let p = phrases[phrase], p.masteredAt != nil else { return false }
        return (now - p.lastPracticedAt) > ProductionProgress.spacedRepetitionWindow
    }

    // MARK: - Persistence (atomic, same pattern as QuizProgressStore)
    private struct FileShape: Codable { var version: Int; var phrases: [String: ProductionProgress] }

    private func save() {
        let shape = FileShape(version: 1, phrases: phrases)
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadFrom(_ url: URL) -> [String: ProductionProgress] {
        guard let data = try? Data(contentsOf: url),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data) else { return [:] }
        return shape.phrases
    }
}
