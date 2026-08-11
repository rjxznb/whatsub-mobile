import Foundation

actor DeepGlossCache {
    static let shared = DeepGlossCache()

    private struct Key: Codable, Hashable {
        let fingerprint: String
        let cueAnchor: String
        let expression: String
    }

    private struct StoredEntry: Codable {
        let key: Key
        let result: DeepGlossResult
        var accessTick: UInt64
    }

    private struct CacheFile: Codable {
        let entries: [StoredEntry]
    }

    private let fileURL: URL
    private let capacity: Int
    private var entries: [Key: StoredEntry] = [:]
    private var accessTick: UInt64 = 0
    private var didLoad = false

    init(fileURL: URL? = nil, capacity: Int = 200) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.capacity = max(1, capacity)
    }

    func value(
        fingerprint: String,
        cueAnchor: String,
        expression: String
    ) -> DeepGlossResult? {
        loadIfNeeded()
        let key = makeKey(
            fingerprint: fingerprint,
            cueAnchor: cueAnchor,
            expression: expression
        )
        guard var entry = entries[key] else { return nil }
        accessTick &+= 1
        entry.accessTick = accessTick
        entries[key] = entry
        persistBestEffort()
        return entry.result
    }

    func store(
        _ result: DeepGlossResult,
        fingerprint: String,
        cueAnchor: String,
        expression: String
    ) {
        loadIfNeeded()
        let key = makeKey(
            fingerprint: fingerprint,
            cueAnchor: cueAnchor,
            expression: expression
        )
        accessTick &+= 1
        entries[key] = StoredEntry(key: key, result: result, accessTick: accessTick)
        evictIfNeeded()
        persistBestEffort()
    }

    private func makeKey(
        fingerprint: String,
        cueAnchor: String,
        expression: String
    ) -> Key {
        Key(
            fingerprint: fingerprint,
            cueAnchor: cueAnchor,
            expression: DeepGlossExpression.normalize(expression)
        )
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(CacheFile.self, from: data)
            for entry in file.entries {
                if let existing = entries[entry.key], existing.accessTick >= entry.accessTick {
                    continue
                }
                entries[entry.key] = entry
                accessTick = max(accessTick, entry.accessTick)
            }
            evictIfNeeded()
        } catch {
            entries = [:]
            accessTick = 0
            persistBestEffort()
        }
    }

    private func evictIfNeeded() {
        while entries.count > capacity,
              let leastRecent = entries.min(by: { lhs, rhs in
                  lhs.value.accessTick < rhs.value.accessTick
              })?.key {
            entries.removeValue(forKey: leastRecent)
        }
    }

    private func persistBestEffort() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let ordered = entries.values.sorted { lhs, rhs in
                lhs.accessTick < rhs.accessTick
            }
            let data = try JSONEncoder().encode(CacheFile(entries: ordered))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cache durability is best-effort. The parsed explanation remains
            // available in memory and the UI must never fail because Caches is
            // temporarily unwritable.
        }
    }

    private static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("deep_gloss_cache.json")
    }
}
