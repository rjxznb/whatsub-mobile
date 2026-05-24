import Foundation

/// Persistent per-phrase quiz progress, stored as JSON in the app's Documents dir.
/// Written immediately after each completed phrase (atomic) so an app kill never loses it.
final class QuizProgressStore {
    private let fileURL: URL
    private var phrases: [String: QuizProgress]

    init(fileURL: URL = QuizProgressStore.defaultURL) {
        self.fileURL = fileURL
        self.phrases = QuizProgressStore.loadFrom(fileURL)
    }

    static var defaultURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("quiz_progress.json")
    }

    func progress(for phrase: String) -> QuizProgress { phrases[phrase] ?? QuizProgress() }
    func snapshot() -> [String: QuizProgress] { phrases }
    func masteredCount(in pool: [String]) -> Int { pool.filter { phrases[$0]?.isMastered ?? false }.count }

    func record(phrase: String, firstTryCorrect: Bool, wrongCount: Int) {
        var p = phrases[phrase] ?? QuizProgress()
        p.seen += 1
        if firstTryCorrect { p.correctFirstTry += 1 }
        p.wrong += wrongCount
        p.lastSeenAt = Int64(Date().timeIntervalSince1970 * 1000)
        phrases[phrase] = p
        save()
    }

    func reset(scopePhrases: [String]) {
        for k in scopePhrases { phrases[k] = nil }
        save()
    }

    // MARK: - Persistence
    private struct FileShape: Codable { var version: Int; var phrases: [String: QuizProgress] }

    private func save() {
        let shape = FileShape(version: 1, phrases: phrases)
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: fileURL, options: .atomic) // .atomic = temp file + rename
    }

    private static func loadFrom(_ url: URL) -> [String: QuizProgress] {
        guard let data = try? Data(contentsOf: url),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data) else { return [:] }
        return shape.phrases
    }
}
