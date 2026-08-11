import CryptoKit
import Foundation

enum AnalysisCheckpointError: LocalizedError {
    case invalidBatchIndex(Int)
    case incompleteBatch(index: Int, expected: Int, actual: Int)
    case mismatchedCueIndex(batch: Int, expected: Int, actual: Int)
    case mismatchedSourceCue(batch: Int, index: Int)
    case corruptCheckpoint

    var errorDescription: String? {
        switch self {
        case .invalidBatchIndex:
            return "解析断点包含无效批次。"
        case .incompleteBatch:
            return "AI 返回的字幕批次不完整，未保存该断点。"
        case .mismatchedCueIndex, .mismatchedSourceCue:
            return "AI 返回的字幕顺序异常，未保存该断点。"
        case .corruptCheckpoint:
            return "解析断点已损坏。"
        }
    }
}

struct AnalysisCheckpoint: Codable {
    struct CompletedBatch: Codable {
        let index: Int
        let cues: [Cue]
    }

    static let schemaVersion = 1

    let version: Int
    let fingerprint: String
    private var batches: [CompletedBatch]
    private(set) var completedSummary: AnalysisSummary?
    var updatedAt: Date

    init(fingerprint: String, updatedAt: Date = Date()) {
        version = Self.schemaVersion
        self.fingerprint = fingerprint
        batches = []
        completedSummary = nil
        self.updatedAt = updatedAt
    }

    var completedBatches: [Int: [Cue]] {
        Dictionary(uniqueKeysWithValues: batches.map { ($0.index, $0.cues) })
    }

    mutating func recordBatch(index: Int, result: [Cue], sourceCues: [Cue]) throws {
        let allBatches = AnalysisEngine.batches(sourceCues)
        guard allBatches.indices.contains(index) else {
            throw AnalysisCheckpointError.invalidBatchIndex(index)
        }
        let expected = allBatches[index]
        guard result.count == expected.count else {
            throw AnalysisCheckpointError.incompleteBatch(
                index: index, expected: expected.count, actual: result.count
            )
        }
        let start = index * 50
        for offset in result.indices {
            let expectedIndex = start + offset
            guard result[offset].index == expectedIndex else {
                throw AnalysisCheckpointError.mismatchedCueIndex(
                    batch: index, expected: expectedIndex, actual: result[offset].index
                )
            }
            guard Self.sameSource(result[offset], expected[offset]) else {
                throw AnalysisCheckpointError.mismatchedSourceCue(batch: index, index: expectedIndex)
            }
        }
        batches.removeAll { $0.index == index }
        batches.append(CompletedBatch(index: index, cues: result))
        batches.sort { $0.index < $1.index }
        updatedAt = Date()
    }

    mutating func recordSummary(_ summary: AnalysisSummary) {
        completedSummary = summary
        updatedAt = Date()
    }

    func validated(sourceCues: [Cue]) throws -> AnalysisCheckpoint {
        guard version == Self.schemaVersion else { throw AnalysisCheckpointError.corruptCheckpoint }
        var seen = Set<Int>()
        for batch in batches {
            guard seen.insert(batch.index).inserted else {
                throw AnalysisCheckpointError.corruptCheckpoint
            }
            var validator = AnalysisCheckpoint(fingerprint: fingerprint)
            try validator.recordBatch(index: batch.index, result: batch.cues, sourceCues: sourceCues)
        }
        if completedSummary != nil {
            let expected = Set(AnalysisEngine.batches(sourceCues).indices)
            guard seen == expected else { throw AnalysisCheckpointError.corruptCheckpoint }
        }
        return self
    }

    private static func sameSource(_ lhs: Cue, _ rhs: Cue) -> Bool {
        // Prompts intentionally serialize timestamps to two decimals. Accept
        // the maximum 5ms rounding delta plus a tiny floating-point margin.
        lhs.text == rhs.text
            && abs(lhs.time - rhs.time) <= 0.0051
            && abs(lhs.endTime - rhs.endTime) <= 0.0051
    }
}

final class AnalysisCheckpointStore: @unchecked Sendable {
    private struct NormalizedCue: Encodable {
        let position: Int
        let startMilliseconds: Int64
        let endMilliseconds: Int64
        let text: String
    }

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = root.appendingPathComponent("AnalysisCheckpoints", isDirectory: true)
        }
    }

    func fingerprint(sourceID: String, cues: [Cue]) -> String {
        let normalized = cues.enumerated().map { position, cue in
            NormalizedCue(
                position: position,
                startMilliseconds: Int64((cue.time * 1_000).rounded()),
                endMilliseconds: Int64((cue.endTime * 1_000).rounded()),
                text: Self.normalize(cue.text)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var input = Data(Self.normalize(sourceID).utf8)
        input.append(0)
        if let encoded = try? encoder.encode(normalized) { input.append(encoded) }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    func makeCheckpoint(sourceID: String, cues: [Cue]) -> AnalysisCheckpoint {
        AnalysisCheckpoint(fingerprint: fingerprint(sourceID: sourceID, cues: cues))
    }

    func load(sourceID: String, cues: [Cue]) throws -> AnalysisCheckpoint? {
        let expected = fingerprint(sourceID: sourceID, cues: cues)
        return try locked {
            let url = fileURL(for: expected)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                let decoded = try decoder.decode(AnalysisCheckpoint.self, from: Data(contentsOf: url))
                guard decoded.fingerprint == expected else {
                    try? fileManager.removeItem(at: url)
                    return nil
                }
                return try decoded.validated(sourceCues: cues)
            } catch {
                // A truncated/old-schema file must never brick imports. It is
                // not trusted as resumable work, so discard it and start clean.
                try? fileManager.removeItem(at: url)
                return nil
            }
        }
    }

    func save(_ checkpoint: AnalysisCheckpoint) throws {
        try locked {
            try ensureDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(checkpoint)
            let url = fileURL(for: checkpoint.fingerprint)
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }

    func delete(sourceID: String, cues: [Cue]) {
        let value = fingerprint(sourceID: sourceID, cues: cues)
        locked {
            try? fileManager.removeItem(at: fileURL(for: value))
        }
    }

    func prune(now: Date = Date(), maxAge: TimeInterval = 7 * 24 * 60 * 60) throws {
        try locked {
            guard fileManager.fileExists(atPath: directory.path) else { return }
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            for url in urls where url.pathExtension == "json" {
                let data = try? Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                let checkpoint = data.flatMap { try? decoder.decode(AnalysisCheckpoint.self, from: $0) }
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let reference = checkpoint?.updatedAt ?? modified ?? .distantPast
                if now.timeIntervalSince(reference) > maxAge {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    private func fileURL(for fingerprint: String) -> URL {
        directory.appendingPathComponent("\(fingerprint).json", isDirectory: false)
    }

    private static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Thread-safe foreground bit read synchronously at request boundaries by the
/// nonisolated analysis engine and written by the MainActor view model.
final class BYOKRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        lock.unlock()
    }

    func canBeginRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

/// Serializes checkpoint callbacks against explicit cancellation. Without this
/// lease, a stream could finish just after `cancelWork()` deleted its file and
/// recreate the supposedly cancelled checkpoint.
final class BYOKCheckpointLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func withValid<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { throw CancellationError() }
        return try body()
    }

    func invalidate(_ cleanup: () -> Void) {
        lock.lock()
        valid = false
        cleanup()
        lock.unlock()
    }
}

final class AnalysisProgressSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private var total = 1

    func update(done: Int, total: Int) {
        lock.lock()
        self.done = done
        self.total = total
        lock.unlock()
    }

    func read() -> (done: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (done, total)
    }
}
