import Foundation
import SwiftUI

/// One phrase staged for cloud sync. Carries the full payload the corpus
/// contribute endpoint needs (so sync is a pure batch loop over `contributePhrase`),
/// plus a local id + timestamp so the staging UI has stable identity + sort.
///
/// Why this exists (build 250+, 2026-06-03): Stage 1 of the corpus refactor
/// made `CollectSheet.save()` POST directly to `/api/corpus/contribute`,
/// burning quota on every collect. Users wanted a stage: collect freely
/// (local, no network), then later pick which ones to actually sync.
struct PendingPhrase: Codable, Identifiable, Equatable {
    let id: UUID
    /// Library entry the phrase came from. Drives source.libraryEntryId on
    /// sync — that's how the cloud knows to route playback to OSS later.
    let entryId: String
    let videoTitle: String
    /// Original YouTube id of the Library entry (when available). Recorded
    /// here so a delete-of-Library-entry-before-sync still preserves the YT
    /// embed fallback when this phrase eventually goes to the cloud.
    let youtubeId: String?
    let phraseRaw: String
    let contextSentence: String
    let meaningZh: String?
    let usageNote: String?
    let timestampSec: Double
    /// epoch seconds — for chronological grouping in the staging UI.
    let collectedAt: Double
}

/// File-backed staging area. Persists to Documents/pending_phrases.json so
/// the queue survives app kills. Singleton because the badge counter on
/// LibraryDetailView + the global Me-tab entry + the staging view all
/// observe the SAME store (`@ObservedObject` wrappers around `.shared`).
///
/// Not annotated `@MainActor` (mirrors `ProductionProgressStore`'s shape —
/// callers are SwiftUI views, naturally main-thread; explicit isolation
/// would forbid the synthesized `static let shared = ...` from compiling
/// under Swift 6 strict concurrency).
final class PendingPhraseStore: ObservableObject {
    static let shared = PendingPhraseStore()

    @Published private(set) var items: [PendingPhrase] = []

    private let fileURL: URL

    init(fileURL: URL = PendingPhraseStore.defaultURL) {
        self.fileURL = fileURL
        self.items = Self.loadFrom(fileURL)
    }

    static var defaultURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("pending_phrases.json")
    }

    // MARK: - mutation

    func add(_ phrase: PendingPhrase) {
        items.append(phrase)
        save()
    }

    /// Remove all listed ids. No-op for ids not in the store.
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    // MARK: - queries

    /// How many pending phrases this Library entry has staged.
    func count(entryId: String) -> Int {
        items.lazy.filter { $0.entryId == entryId }.count
    }

    /// All staged phrases, in collection order (oldest first).
    var total: Int { items.count }

    /// Grouped-by-video view used by the staging UI. Groups sorted by most
    /// recent collection within the group (so the video you just collected
    /// from floats to the top); items inside a group sorted by timestamp
    /// (so they read in video-playback order).
    var byVideo: [PendingGroup] {
        let groups = Dictionary(grouping: items, by: { $0.entryId })
        return groups
            .map { (key, value) -> PendingGroup in
                let sorted = value.sorted { $0.timestampSec < $1.timestampSec }
                let mostRecent = value.map(\.collectedAt).max() ?? 0
                return PendingGroup(
                    entryId: key,
                    videoTitle: value.first?.videoTitle ?? "",
                    items: sorted,
                    mostRecentCollectedAt: mostRecent
                )
            }
            .sorted { $0.mostRecentCollectedAt > $1.mostRecentCollectedAt }
    }

    // MARK: - persistence (atomic write, mirrors the old VocabStore pattern)

    private struct FileShape: Codable { var version: Int; var items: [PendingPhrase] }

    private func save() {
        let shape = FileShape(version: 1, items: items)
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadFrom(_ url: URL) -> [PendingPhrase] {
        guard let data = try? Data(contentsOf: url),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data) else { return [] }
        return shape.items
    }
}

/// One bucket in the staging UI — all phrases collected from the same video.
struct PendingGroup: Identifiable {
    var id: String { entryId }
    let entryId: String
    let videoTitle: String
    let items: [PendingPhrase]
    let mostRecentCollectedAt: Double
}
