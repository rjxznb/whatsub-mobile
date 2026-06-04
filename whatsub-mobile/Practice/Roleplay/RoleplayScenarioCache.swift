import Foundation

/// Per-Library-entry cache of LLM-derived `RoleplayScenario`s. Lives in
/// `Caches/roleplay_scenarios.json`. Each tab open now reads this first;
/// only the "重新生成" button (or an empty cache) triggers a fresh LLM
/// call.
///
/// Why a separate file (vs. UserDefaults / corpus_cache): the scenes
/// are larger than UserDefaults' soft "few KBs" budget when a user has
/// 50+ Library entries each with 1-3 scenarios, and they're naturally
/// regeneratable — Caches/ is the right semantic bucket. Same atomic
/// write pattern as `PendingPhraseStore` + `ProductionProgressStore`.
///
/// 2026-06-04 (roleplay tab persistence).
struct RoleplayScenarioCache {
    private let fileURL: URL

    init(fileURL: URL = RoleplayScenarioCache.defaultURL) {
        self.fileURL = fileURL
    }

    static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("roleplay_scenarios.json")
    }

    /// One row in the cache — the scenarios + when they were generated +
    /// a fingerprint of the corpus phrases at derivation time. The
    /// fingerprint lets us optionally invalidate when the user has
    /// added/removed phrases for this video since (out of scope for
    /// v1 — we just store it for future-proofing).
    struct Entry: Codable {
        var scenarios: [RoleplayScenario]
        var corpusPhraseFingerprint: Int
        var savedAt: Double   // epoch seconds
    }

    private struct FileShape: Codable {
        var version: Int
        var entries: [String: Entry]   // key: Library entry id
    }

    /// Return cached scenarios for the entry (whether or not the
    /// fingerprint matches the current corpus phrases — fingerprint
    /// drift is informational, not invalidating).
    func get(entryId: String) -> Entry? {
        let shape = Self.load(from: fileURL)
        return shape.entries[entryId]
    }

    /// Persist scenarios for one entry. Overwrites any previous row.
    func put(entryId: String, scenarios: [RoleplayScenario], corpusPhrases: [String]) {
        var shape = Self.load(from: fileURL)
        shape.entries[entryId] = Entry(
            scenarios: scenarios,
            corpusPhraseFingerprint: Self.fingerprint(of: corpusPhrases),
            savedAt: Date().timeIntervalSince1970
        )
        Self.save(shape: shape, to: fileURL)
    }

    /// Clear the cache row for one entry (called by the Library
    /// delete-from-cloud path — keeps the file from accumulating
    /// orphans). No-op when the row is absent.
    func remove(entryId: String) {
        var shape = Self.load(from: fileURL)
        if shape.entries.removeValue(forKey: entryId) != nil {
            Self.save(shape: shape, to: fileURL)
        }
    }

    /// Stable hash of the user's corpus phrases (normalized + sorted)
    /// used at derivation time. Drift is harmless — the cache hit still
    /// returns scenarios, just ones generated from a slightly different
    /// phrase set. The user can hit "重新生成" if it bothers them.
    static func fingerprint(of phrases: [String]) -> Int {
        let normalized = phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
        // Hasher gives a per-launch-stable Int from a sequence — good
        // enough for drift detection (no security implications).
        var hasher = Hasher()
        for s in normalized { hasher.combine(s) }
        return hasher.finalize()
    }

    // MARK: - persistence

    private static func load(from url: URL) -> FileShape {
        guard let data = try? Data(contentsOf: url),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data)
        else {
            return FileShape(version: 1, entries: [:])
        }
        return shape
    }

    private static func save(shape: FileShape, to url: URL) {
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
