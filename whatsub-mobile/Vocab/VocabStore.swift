import Foundation
import Combine

/// Local per-video vocab notebooks, persisted to `Documents/vocab_notebooks.json`
/// (`[entryId: [VocabItem]]`). The special key `stagingKey` is a global "暂存区"
/// notebook not tied to any video — where phrases migrate when their video is
/// deleted. Mirrors the load-on-init / rewrite-on-mutation pattern used by the
/// quiz progress store. Not actor-isolated: it's a small local JSON store accessed
/// only from main-thread UI actions, so direct `VocabStore.shared` use from view
/// bodies/helpers needs no isolation hops.
final class VocabStore: ObservableObject {
    static let shared = VocabStore()
    static let stagingKey = "__staging__"

    /// entryId → its saved phrases. Private setter; mutate via the methods below.
    @Published private(set) var books: [String: [VocabItem]] = [:]

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("vocab_notebooks.json")
    }

    init() { load() }

    // MARK: - Reads

    /// Items for a book, newest first.
    func items(for entryId: String) -> [VocabItem] {
        (books[entryId] ?? []).sorted { $0.savedAt > $1.savedAt }
    }

    func count(for entryId: String) -> Int { books[entryId]?.count ?? 0 }

    // MARK: - Mutations

    func add(_ item: VocabItem, to entryId: String) {
        books[entryId, default: []].append(item)
        save()
    }

    func remove(itemId: String, from entryId: String) {
        guard var list = books[entryId] else { return }
        list.removeAll { $0.id == itemId }
        if list.isEmpty { books[entryId] = nil } else { books[entryId] = list }
        save()
    }

    func updateNote(itemId: String, in entryId: String, note: String) {
        guard var list = books[entryId], let i = list.firstIndex(where: { $0.id == itemId }) else { return }
        list[i].note = note
        books[entryId] = list
        save()
    }

    /// Move every item from `source` into `target`, then drop the source book.
    /// When the target is a different video (not the same book, not just staging
    /// re-add), the per-cue jump no longer applies — `cueIndex` is cleared but the
    /// originating `sourceTitle` is kept so the user still knows where it came from.
    func migrate(from source: String, to target: String) {
        guard source != target, let moving = books[source], !moving.isEmpty else { return }
        let adjusted = moving.map { item -> VocabItem in
            var copy = item
            copy.cueIndex = nil
            return copy
        }
        books[target, default: []].append(contentsOf: adjusted)
        books[source] = nil
        save()
    }

    func deleteBook(_ entryId: String) {
        guard books[entryId] != nil else { return }
        books[entryId] = nil
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: [VocabItem]].self, from: data) else { return }
        books = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
