import Foundation

struct CachedList<T: Codable>: Codable {
    var items: [T] = []
    var tags: [CorpusTag] = []
    var fetchedAt: Double = 0   // epoch seconds
    var atMine = -1
    var atPublic = -1
}

struct CachedLookup: Codable {
    var response: LookupResponse
    var fetchedAt: Double
    var atMine: Int
    var atPublic: Int
}

struct CorpusCacheFile: Codable {
    var version = 1
    var mineVersion = -1
    var publicVersion = -1
    var browse = CachedList<BrowsePhrase>()   // public scope, unfiltered
    var mine = CachedList<MineItem>()           // mine scope, unfiltered
    var lookups: [String: CachedLookup] = [:]
    var lookupOrder: [String] = []              // LRU, most-recent at the end
}

/// On-disk corpus cache (`Caches/corpus_cache.json`). Accessed from @MainActor
/// view models. Tagged with the {mine, public} versions each item was fetched
/// under; valid while those match the latest /versions and within the TTL.
final class CorpusCache {
    static let shared = CorpusCache()

    private let fileURL: URL
    private let ttl: TimeInterval
    private let lookupCap = 500
    private var file: CorpusCacheFile

    init(fileURL: URL = CorpusCache.defaultURL, ttl: TimeInterval = 24 * 3600) {
        self.fileURL = fileURL
        self.ttl = ttl
        self.file = CorpusCache.load(fileURL)
    }

    static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("corpus_cache.json")
    }

    var mineVersion: Int { file.mineVersion }
    var publicVersion: Int { file.publicVersion }

    func updateVersions(mine: Int, publicVersion: Int) {
        file.mineVersion = mine
        file.publicVersion = publicVersion
        save()
    }

    // MARK: List
    func cachedBrowse() -> (items: [BrowsePhrase], tags: [CorpusTag])? {
        file.browse.items.isEmpty ? nil : (file.browse.items, file.browse.tags)
    }
    func cachedMine() -> (items: [MineItem], tags: [CorpusTag])? {
        file.mine.items.isEmpty ? nil : (file.mine.items, file.mine.tags)
    }
    func isBrowseStale(now: Date) -> Bool {
        file.browse.items.isEmpty
            || file.browse.atPublic != file.publicVersion
            || now.timeIntervalSince1970 - file.browse.fetchedAt > ttl
    }
    func isMineStale(now: Date) -> Bool {
        file.mine.items.isEmpty
            || file.mine.atMine != file.mineVersion
            || now.timeIntervalSince1970 - file.mine.fetchedAt > ttl
    }
    func storeBrowse(items: [BrowsePhrase], tags: [CorpusTag], now: Date) {
        file.browse = CachedList(items: items, tags: tags,
                                 fetchedAt: now.timeIntervalSince1970,
                                 atMine: file.mineVersion, atPublic: file.publicVersion)
        save()
    }
    func storeMine(items: [MineItem], tags: [CorpusTag], now: Date) {
        file.mine = CachedList(items: items, tags: tags,
                               fetchedAt: now.timeIntervalSince1970,
                               atMine: file.mineVersion, atPublic: file.publicVersion)
        save()
    }

    // MARK: Lookup
    func cachedLookup(_ phrase: String, now: Date) -> LookupResponse? {
        guard let entry = file.lookups[phrase],
              entry.atMine == file.mineVersion,
              entry.atPublic == file.publicVersion,
              now.timeIntervalSince1970 - entry.fetchedAt < ttl
        else { return nil }
        touchLRU(phrase)   // mark most-recently-used
        save()
        return entry.response
    }
    func storeLookup(_ phrase: String, _ response: LookupResponse, now: Date) {
        file.lookups[phrase] = CachedLookup(response: response, fetchedAt: now.timeIntervalSince1970,
                                            atMine: file.mineVersion, atPublic: file.publicVersion)
        touchLRU(phrase)
        while file.lookupOrder.count > lookupCap {
            let evict = file.lookupOrder.removeFirst()
            file.lookups[evict] = nil
        }
        save()
    }

    private func touchLRU(_ phrase: String) {
        file.lookupOrder.removeAll { $0 == phrase }
        file.lookupOrder.append(phrase)
    }

    // MARK: Persistence
    private func save() {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
    private static func load(_ url: URL) -> CorpusCacheFile {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(CorpusCacheFile.self, from: data) else {
            return CorpusCacheFile()
        }
        return f
    }
}
