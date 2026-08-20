import CryptoKit
import Foundation

struct AppleTranslationRequestItem: Equatable {
    let cueIndex: Int
    let sourceText: String
}

enum AppleTranslationFallback {
    static func isEligible(
        status: ManagedAnalysisJobStatus,
        errorCode: ManagedAnalysisFailureCode?
    ) -> Bool {
        guard status == .failed else { return false }
        switch errorCode {
        case .upstreamUnavailable, .invalidAnalysisCue, .invalidSSE:
            return true
        case .freeUsedUp, .quotaExceeded, .videoTooLong, .durationUnknown, nil:
            return false
        }
    }

    static func requests(from cues: [Cue]) -> [AppleTranslationRequestItem] {
        cues.compactMap { cue in
            guard cue.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AppleTranslationRequestItem(cueIndex: cue.index, sourceText: cue.text)
        }
    }

    static func applying(
        translation: String,
        toCueIndex cueIndex: Int,
        in cues: [Cue]
    ) -> [Cue] {
        let value = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return cues }
        var updated = cues
        guard let position = updated.firstIndex(where: { $0.index == cueIndex }),
              updated[position].translation
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cues
        }
        updated[position].translation = value
        return updated
    }
}

enum AppleTranslationFallbackPhase: Equatable {
    case idle
    case preparing(total: Int)
    case translating(completed: Int, total: Int)
    case syncing
    case completed
    case unavailable(String)
    case syncFailed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .translating, .syncing: return true
        case .idle, .completed, .unavailable, .syncFailed: return false
        }
    }

    var shouldRunTranslationTask: Bool {
        if case .preparing = self { return true }
        return false
    }

    var label: String? {
        switch self {
        case .idle: return nil
        case .preparing: return "AI 服务不可用 · 准备设备端翻译"
        case let .translating(completed, total):
            return "Apple 设备端翻译中 · \(completed)/\(total)"
        case .syncing: return "设备端翻译完成 · 正在同步"
        case .completed: return nil
        case .unavailable: return "仅英文 · 系统翻译不可用"
        case .syncFailed: return "设备端翻译已保留 · 云同步待重试"
        }
    }

    var fraction: Double? {
        switch self {
        case let .preparing(total): return total == 0 ? 1 : 0
        case let .translating(completed, total):
            guard total > 0 else { return 1 }
            return min(max(Double(completed) / Double(total), 0), 1)
        case .syncing: return 1
        case .idle, .completed, .unavailable, .syncFailed: return nil
        }
    }

    var detail: String? {
        switch self {
        case let .unavailable(message), let .syncFailed(message): return message
        case .idle, .preparing, .translating, .syncing, .completed: return nil
        }
    }
}

private struct AppleTranslationCheckpoint: Codable {
    static let schemaVersion = 1

    let version: Int
    let entryID: String
    let sourceFingerprint: String
    let translations: [String: String]
}

/// Crash-safe, per-response persistence for Apple Translation. The file is
/// validated against the immutable English cue/timing fingerprint before use,
/// so an edited/replaced transcript can never inherit stale translations.
final class AppleTranslationCheckpointStore {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            self.directory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("AppleTranslationFallback", isDirectory: true)
        }
    }

    func load(entryID: String, sourceCues: [Cue]) throws -> [Int: String] {
        let data = try Data(contentsOf: fileURL(entryID: entryID))
        let checkpoint = try JSONDecoder().decode(AppleTranslationCheckpoint.self, from: data)
        guard checkpoint.version == AppleTranslationCheckpoint.schemaVersion,
              checkpoint.entryID == entryID,
              checkpoint.sourceFingerprint == fingerprint(entryID: entryID, cues: sourceCues) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: checkpoint.translations.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    func save(entryID: String, sourceCues: [Cue], translatedCues: [Cue]) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let translations = Dictionary(uniqueKeysWithValues: translatedCues.compactMap { cue in
            let value = cue.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : (String(cue.index), value)
        })
        let checkpoint = AppleTranslationCheckpoint(
            version: AppleTranslationCheckpoint.schemaVersion,
            entryID: entryID,
            sourceFingerprint: fingerprint(entryID: entryID, cues: sourceCues),
            translations: translations
        )
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(
            to: fileURL(entryID: entryID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func delete(entryID: String) {
        try? fileManager.removeItem(at: fileURL(entryID: entryID))
    }

    private func fileURL(entryID: String) -> URL {
        let digest = SHA256.hash(data: Data(entryID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    private func fingerprint(entryID: String, cues: [Cue]) -> String {
        var input = Data(entryID.utf8)
        for cue in cues.sorted(by: { $0.index < $1.index }) {
            input.append(Data("\u{1f}\(cue.index)\u{1f}\(cue.time)\u{1f}\(cue.endTime)\u{1f}\(cue.text)".utf8))
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
