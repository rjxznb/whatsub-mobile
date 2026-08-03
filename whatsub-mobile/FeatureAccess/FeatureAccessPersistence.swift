import Foundation

private struct FeatureAccessAccountFile: Codable {
    var snapshot: FeatureAccessSnapshot?
    var pendingConsumes: Set<FeatureKey> = []
}

private struct FeatureAccessFile: Codable {
    var version = 1
    var accounts: [String: FeatureAccessAccountFile] = [:]
}

/// Durable account-scoped feature state. Only entitlement snapshots and
/// pending consume markers live here; grants and all user/AI content remain
/// in memory and are never written to this file.
final class FeatureAccessPersistence {
    static let shared = FeatureAccessPersistence()

    private let fileURL: URL
    private var file: FeatureAccessFile

    init(fileURL: URL = FeatureAccessPersistence.defaultURL) {
        self.fileURL = fileURL
        self.file = Self.load(fileURL)
    }

    static var defaultURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("feature_access.json")
    }

    func snapshot(for email: String) -> FeatureAccessSnapshot? {
        file.accounts[Self.accountKey(email)]?.snapshot
    }

    func store(snapshot: FeatureAccessSnapshot, for email: String) {
        let key = Self.accountKey(email)
        var account = file.accounts[key] ?? FeatureAccessAccountFile()
        account.snapshot = snapshot
        file.accounts[key] = account
        save()
    }

    func pendingConsumes(email: String) -> Set<FeatureKey> {
        file.accounts[Self.accountKey(email)]?.pendingConsumes ?? []
    }

    /// Synchronous + atomic on purpose: the crash-retry marker must be on
    /// disk before a valuable AI result is allowed to become visible.
    func addPendingConsume(_ feature: FeatureKey, email: String) {
        let key = Self.accountKey(email)
        var account = file.accounts[key] ?? FeatureAccessAccountFile()
        account.pendingConsumes.insert(feature)
        file.accounts[key] = account
        save()
    }

    func removePendingConsume(_ feature: FeatureKey, email: String) {
        let key = Self.accountKey(email)
        guard var account = file.accounts[key] else { return }
        account.pendingConsumes.remove(feature)
        file.accounts[key] = account
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(_ url: URL) -> FeatureAccessFile {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FeatureAccessFile.self, from: data) else {
            return FeatureAccessFile()
        }
        return decoded
    }

    private static func accountKey(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
