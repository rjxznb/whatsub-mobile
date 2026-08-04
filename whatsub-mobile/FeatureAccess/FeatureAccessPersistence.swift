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

    func store(snapshot: FeatureAccessSnapshot, for email: String) throws {
        try update { next in
            let key = Self.accountKey(email)
            var account = next.accounts[key] ?? FeatureAccessAccountFile()
            account.snapshot = snapshot
            next.accounts[key] = account
        }
    }

    func pendingConsumes(email: String) -> Set<FeatureKey> {
        file.accounts[Self.accountKey(email)]?.pendingConsumes ?? []
    }

    /// Synchronous + atomic on purpose: the crash-retry marker must be on
    /// disk before a valuable AI result is allowed to become visible.
    func addPendingConsume(_ feature: FeatureKey, email: String) throws {
        try update { next in
            let key = Self.accountKey(email)
            var account = next.accounts[key] ?? FeatureAccessAccountFile()
            account.pendingConsumes.insert(feature)
            next.accounts[key] = account
        }
    }

    func removePendingConsume(_ feature: FeatureKey, email: String) throws {
        guard file.accounts[Self.accountKey(email)] != nil else { return }
        try update { next in
            let key = Self.accountKey(email)
            guard var account = next.accounts[key] else { return }
            account.pendingConsumes.remove(feature)
            next.accounts[key] = account
        }
    }

    func removeAccount(email: String) throws {
        guard file.accounts[Self.accountKey(email)] != nil else { return }
        do {
            try update { next in
                next.accounts.removeValue(forKey: Self.accountKey(email))
            }
        } catch {
            // Account deletion is a privacy boundary. If rewriting the
            // account map fails, discard the whole cache instead of retaining
            // the deleted account's trial markers. Other accounts simply
            // rehydrate their small snapshots from the server.
            try FileManager.default.removeItem(at: fileURL)
            file = FeatureAccessFile()
        }
    }

    /// Write a copy first and only publish it to memory after the atomic disk
    /// write succeeds. This prevents an I/O failure from looking durable for
    /// the rest of the process while being absent after a relaunch.
    private func update(_ mutate: (inout FeatureAccessFile) -> Void) throws {
        var next = file
        mutate(&next)
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        file = next
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
