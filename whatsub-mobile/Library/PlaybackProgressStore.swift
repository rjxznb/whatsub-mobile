import Foundation

actor PlaybackProgressStore {
    static let shared = PlaybackProgressStore()

    private struct Envelope: Codable {
        let version: Int
        var records: [String: Record]
    }

    private struct Record: Codable {
        var position: Double
        var lastAccessedAt: Date
    }

    private let fileURL: URL
    private let capacity: Int
    private var records: [String: Record]?

    init(fileURL: URL? = nil, capacity: Int = 500) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.capacity = max(1, capacity)
    }

    func position(for entryID: String) -> Double? {
        guard let key = normalizedEntryID(entryID) else { return nil }
        loadIfNeeded()
        guard var record = records?[key] else { return nil }
        record.lastAccessedAt = Date()
        records?[key] = record
        persist()
        return record.position
    }

    func save(position: Double, for entryID: String, now: Date = Date()) {
        guard position.isFinite, position >= 0,
              let key = normalizedEntryID(entryID) else { return }
        loadIfNeeded()
        records?[key] = Record(position: floor(position), lastAccessedAt: now)
        trimToCapacity()
        persist()
    }

    func clear(entryID: String) {
        guard let key = normalizedEntryID(entryID) else { return }
        loadIfNeeded()
        guard records?.removeValue(forKey: key) != nil else { return }
        persist()
    }

    private static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whatsub", isDirectory: true)
            .appendingPathComponent("playback_progress.json")
    }

    private func normalizedEntryID(_ entryID: String) -> String? {
        let value = entryID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func loadIfNeeded() {
        guard records == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1 else {
            records = [:]
            return
        }
        records = envelope.records.filter { _, record in
            record.position.isFinite && record.position >= 0
        }
        trimToCapacity()
    }

    private func trimToCapacity() {
        guard var current = records else { return }
        while current.count > capacity,
              let oldest = current.min(by: {
                  $0.value.lastAccessedAt < $1.value.lastAccessedAt
              })?.key {
            current.removeValue(forKey: oldest)
        }
        records = current
    }

    private func persist() {
        guard let records else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(
            Envelope(version: 1, records: records)
        ) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
