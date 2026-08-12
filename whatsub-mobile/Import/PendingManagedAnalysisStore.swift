import Foundation

struct PendingManagedAnalysisSubmission: Codable, Equatable, Identifiable {
    let requestID: String
    let ownerEmail: String
    let request: ManagedAnalysisCreateRequest
    let createdAt: Date
    let nextRetryAt: Date
    let retryCount: Int

    var id: String { "\(ownerEmail)\u{0}\(requestID)" }
}

actor PendingManagedAnalysisStore {
    static let shared = PendingManagedAnalysisStore()
    private static let purgeStateLock = NSLock()
    nonisolated(unsafe) private static var synchronouslyPurgedPaths: Set<String> = []

    enum StoreError: Error, Equatable {
        case missingOwner
    }

    private struct Envelope: Codable {
        let version: Int
        let submissions: [PendingManagedAnalysisSubmission]
    }

    private static let currentVersion = 1
    private static let defaultMaximumEntries = 10
    private static let defaultLifetime: TimeInterval = 24 * 60 * 60
    private static let minimumRetryDelay: TimeInterval = 5
    private static let maximumRetryDelay: TimeInterval = 5 * 60

    private let fileURL: URL
    private let fileManager: FileManager
    private let maximumEntries: Int
    private let lifetime: TimeInterval

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumEntries: Int = PendingManagedAnalysisStore.defaultMaximumEntries,
        lifetime: TimeInterval = PendingManagedAnalysisStore.defaultLifetime
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.maximumEntries = max(1, maximumEntries)
        self.lifetime = max(1, lifetime)
    }

    /// Logout is synchronous from SwiftUI. Remove the default payload before
    /// returning control so an immediate process kill cannot leave captions,
    /// title, URL, or thumbnail bytes on disk. Actor-owned cleanup still runs
    /// afterwards to cancel work and notify observers.
    nonisolated static func removeDefaultFileSynchronously(
        fileManager: FileManager = .default
    ) {
        removeFileSynchronously(
            at: defaultFileURL(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    nonisolated static func removeFileSynchronously(
        at url: URL,
        fileManager: FileManager = .default
    ) {
        purgeStateLock.lock()
        defer { purgeStateLock.unlock() }
        synchronouslyPurgedPaths.insert(url.standardizedFileURL.path)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    func enqueue(
        request: ManagedAnalysisCreateRequest,
        ownerEmail: String,
        retryAfterSeconds: Int?,
        at now: Date = Date()
    ) throws -> PendingManagedAnalysisSubmission {
        // A new explicit import after login owns the file again. Stale
        // reschedule/remove operations never call this and remain fenced out.
        let owner = try normalizedOwner(ownerEmail)
        Self.allowWrites(to: fileURL)
        var submissions = try load(at: now)

        if let existing = submissions.first(where: {
            $0.ownerEmail == owner && $0.requestID == request.idempotencyKey
        }) {
            return existing
        }

        let delay = retryDelay(retryCount: 1, serverSeconds: retryAfterSeconds)
        let submission = PendingManagedAnalysisSubmission(
            requestID: request.idempotencyKey,
            ownerEmail: owner,
            request: request,
            createdAt: now,
            nextRetryAt: now.addingTimeInterval(delay),
            retryCount: 1
        )
        submissions.append(submission)
        submissions.sort(by: oldestFirst)
        if submissions.count > maximumEntries {
            submissions.removeFirst(submissions.count - maximumEntries)
        }
        try persist(submissions)
        return submission
    }

    func all(at now: Date = Date()) throws -> [PendingManagedAnalysisSubmission] {
        try load(at: now)
    }

    func ready(
        ownerEmail: String,
        limit: Int,
        at now: Date = Date()
    ) throws -> [PendingManagedAnalysisSubmission] {
        let owner = try normalizedOwner(ownerEmail)
        return try load(at: now)
            .filter { $0.ownerEmail == owner && $0.nextRetryAt <= now }
            .sorted(by: nextRetryFirst)
            .prefix(max(0, limit))
            .map { $0 }
    }

    func next(
        ownerEmail: String,
        at now: Date = Date()
    ) throws -> PendingManagedAnalysisSubmission? {
        let owner = try normalizedOwner(ownerEmail)
        return try load(at: now)
            .filter { $0.ownerEmail == owner }
            .min { nextRetryFirst($0, $1) }
    }

    @discardableResult
    func reschedule(
        requestID: String,
        ownerEmail: String,
        retryAfterSeconds: Int?,
        at now: Date = Date()
    ) throws -> PendingManagedAnalysisSubmission? {
        let owner = try normalizedOwner(ownerEmail)
        var submissions = try load(at: now)
        guard let index = submissions.firstIndex(where: {
            $0.ownerEmail == owner && $0.requestID == requestID
        }) else { return nil }

        let existing = submissions[index]
        let retryCount = existing.retryCount + 1
        let delay = retryDelay(
            retryCount: retryCount,
            serverSeconds: retryAfterSeconds
        )
        let updated = PendingManagedAnalysisSubmission(
            requestID: existing.requestID,
            ownerEmail: existing.ownerEmail,
            request: existing.request,
            createdAt: existing.createdAt,
            nextRetryAt: now.addingTimeInterval(delay),
            retryCount: retryCount
        )
        submissions[index] = updated
        try persist(submissions)
        return updated
    }

    func remove(
        requestID: String,
        ownerEmail: String,
        at now: Date = Date()
    ) throws {
        let owner = try normalizedOwner(ownerEmail)
        var submissions = try load(at: now)
        submissions.removeAll {
            $0.ownerEmail == owner && $0.requestID == requestID
        }
        try persist(submissions)
    }

    func removeAll(ownerEmail: String, at now: Date = Date()) throws {
        let owner = try normalizedOwner(ownerEmail)
        var submissions = try load(at: now)
        submissions.removeAll { $0.ownerEmail == owner }
        try persist(submissions)
    }

    private func load(at now: Date) throws -> [PendingManagedAnalysisSubmission] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        let decoded: Envelope
        do {
            let data = try Data(contentsOf: fileURL)
            decoded = try JSONDecoder().decode(Envelope.self, from: data)
            guard decoded.version == Self.currentVersion else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "unsupported version")
                )
            }
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return []
        }

        let expiry = now.addingTimeInterval(-lifetime)
        let live = decoded.submissions
            .filter { $0.createdAt > expiry }
            .sorted(by: oldestFirst)
        if live != decoded.submissions {
            try persist(live)
        }
        return live
    }

    private func persist(_ submissions: [PendingManagedAnalysisSubmission]) throws {
        // AppState marks the path before its synchronous logout deletion.
        // Any actor operation that loaded the old file just before logout is
        // therefore prevented from recreating it afterwards.
        Self.purgeStateLock.lock()
        defer { Self.purgeStateLock.unlock() }
        if submissions.isEmpty {
            // Always retry deletion, even after the synchronous logout delete
            // failed. The purge fence only blocks non-empty stale rewrites.
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
        guard !Self.synchronouslyPurgedPaths.contains(
            fileURL.standardizedFileURL.path
        ) else { return }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
        let envelope = Envelope(
            version: Self.currentVersion,
            submissions: submissions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    private func normalizedOwner(_ ownerEmail: String) throws -> String {
        let owner = ownerEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !owner.isEmpty else { throw StoreError.missingOwner }
        return owner
    }

    private func retryDelay(retryCount: Int, serverSeconds: Int?) -> TimeInterval {
        let exponent = min(max(retryCount - 1, 0), 10)
        let exponential = Self.minimumRetryDelay * pow(2, Double(exponent))
        let requested = max(exponential, TimeInterval(max(0, serverSeconds ?? 0)))
        return min(requested, Self.maximumRetryDelay)
    }

    private func oldestFirst(
        _ lhs: PendingManagedAnalysisSubmission,
        _ rhs: PendingManagedAnalysisSubmission
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    private func nextRetryFirst(
        _ lhs: PendingManagedAnalysisSubmission,
        _ rhs: PendingManagedAnalysisSubmission
    ) -> Bool {
        if lhs.nextRetryAt != rhs.nextRetryAt { return lhs.nextRetryAt < rhs.nextRetryAt }
        return oldestFirst(lhs, rhs)
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("whatSub", isDirectory: true)
            .appendingPathComponent("pending-managed-analysis.json")
    }

    private nonisolated static func allowWrites(to url: URL) {
        purgeStateLock.lock()
        synchronouslyPurgedPaths.remove(url.standardizedFileURL.path)
        purgeStateLock.unlock()
    }
}
