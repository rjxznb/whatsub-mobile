import Foundation

struct LibraryCacheFile: Codable {
    var version = 1
    /// Whose library this is. Checked on every read so a logout → login with
    /// a different account can never render the previous user's list.
    /// (CorpusCache predates this concern; corpus data is less sensitive.)
    var ownerEmail = ""
    /// Server fingerprint (`GET /api/library/version`) the entries were
    /// fetched under. -1 = never stored.
    var serverVersion = -1
    var entries: [LibraryListItem] = []
    var fetchedAt: Double = 0   // epoch seconds; 0 = never stored
}

/// On-disk Library list cache (`Caches/library_cache.json`), mirror of
/// CorpusCache's cache-first flow:
///
///   open tab   → render cached entries instantly (offline-friendly)
///   refresh    → GET /version (one number) → equal to cached + within TTL?
///                → done, zero list traffic. Different? → full /list + store.
///
/// `fetchedAt > 0` (not `entries.isEmpty`) marks "has cache" — an EMPTY
/// library is a valid cached state (new user), unlike corpus where an empty
/// list is indistinguishable from cold start.
final class LibraryCache {
    static let shared = LibraryCache()

    private let fileURL: URL
    private let ttl: TimeInterval
    private var file: LibraryCacheFile

    init(fileURL: URL = LibraryCache.defaultURL, ttl: TimeInterval = 24 * 3600) {
        self.fileURL = fileURL
        self.ttl = ttl
        self.file = LibraryCache.load(fileURL)
    }

    static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("library_cache.json")
    }

    /// Entries + the server version they were fetched under, or nil when
    /// nothing was ever stored / the cache belongs to a different account.
    func cached(for email: String) -> (entries: [LibraryListItem], version: Int)? {
        guard file.fetchedAt > 0, file.ownerEmail == email else { return nil }
        return (file.entries, file.serverVersion)
    }

    /// True when the cached list can be shown WITHOUT refetching /list:
    /// same owner + fingerprint matches the server's + within TTL.
    func isFresh(for email: String, serverVersion: Int, now: Date) -> Bool {
        file.fetchedAt > 0
            && file.ownerEmail == email
            && file.serverVersion == serverVersion
            && now.timeIntervalSince1970 - file.fetchedAt < ttl
    }

    func store(entries: [LibraryListItem], version: Int, for email: String, now: Date) {
        file = LibraryCacheFile(
            ownerEmail: email,
            serverVersion: version,
            entries: entries,
            fetchedAt: now.timeIntervalSince1970
        )
        save()
    }

    /// Drop the cache entirely — used after local mutations (delete) so the
    /// next refresh refetches instead of resurrecting the removed row.
    func clear() {
        file = LibraryCacheFile()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Persistence
    private func save() {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
    private static func load(_ url: URL) -> LibraryCacheFile {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(LibraryCacheFile.self, from: data) else {
            return LibraryCacheFile()
        }
        return f
    }
}
