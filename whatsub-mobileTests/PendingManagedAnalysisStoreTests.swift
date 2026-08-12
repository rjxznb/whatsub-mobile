import XCTest
@testable import whatsub_mobile

final class PendingManagedAnalysisStoreTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        fileURL = temporaryDirectory.appendingPathComponent("pending-managed-analysis.json")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testEnqueuePersistsRequestAtomicallyWithFileProtection() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = PendingManagedAnalysisStore(fileURL: fileURL)
        let request = makeRequest(id: "request-1")

        let saved = try await store.enqueue(
            request: request,
            ownerEmail: " User@Example.com ",
            retryAfterSeconds: 7,
            at: now
        )

        XCTAssertEqual(saved.requestID, "request-1")
        XCTAssertEqual(saved.ownerEmail, "user@example.com")
        XCTAssertEqual(saved.request, request)
        XCTAssertEqual(saved.createdAt, now)
        XCTAssertEqual(saved.nextRetryAt, now.addingTimeInterval(7))

        let reloaded = PendingManagedAnalysisStore(fileURL: fileURL)
        let entries = try await reloaded.all(at: now)
        XCTAssertEqual(entries, [saved])
        let persistedFiles = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(persistedFiles.map(\.lastPathComponent), [fileURL.lastPathComponent])

        #if os(iOS) && !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
    }

    func testEnqueueDeduplicatesByStableRequestIDWithoutChangingPayload() async throws {
        let store = PendingManagedAnalysisStore(fileURL: fileURL)
        let original = makeRequest(id: "stable-request", title: "Original")
        let conflictingDuplicate = makeRequest(id: "stable-request", title: "Changed")

        let first = try await store.enqueue(
            request: original,
            ownerEmail: "user@example.com",
            retryAfterSeconds: 5,
            at: Date(timeIntervalSince1970: 100)
        )
        let second = try await store.enqueue(
            request: conflictingDuplicate,
            ownerEmail: "USER@example.com",
            retryAfterSeconds: 30,
            at: Date(timeIntervalSince1970: 110)
        )

        let entries = try await store.all(at: Date(timeIntervalSince1970: 111))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].requestID, first.requestID)
        XCTAssertEqual(entries[0].createdAt, first.createdAt)
        XCTAssertEqual(entries[0].request.title, "Original")
        XCTAssertEqual(second, entries[0])
    }

    func testStoreKeepsNewestTenPendingSubmissions() async throws {
        let store = PendingManagedAnalysisStore(fileURL: fileURL)

        for index in 0..<12 {
            _ = try await store.enqueue(
                request: makeRequest(id: "request-\(index)"),
                ownerEmail: "user@example.com",
                retryAfterSeconds: 5,
                at: Date(timeIntervalSince1970: Double(index))
            )
        }

        let entries = try await store.all(at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.map(\.requestID), (2..<12).map { "request-\($0)" })
    }

    func testEntriesExpireAfterTwentyFourHours() async throws {
        let store = PendingManagedAnalysisStore(fileURL: fileURL)
        let created = Date(timeIntervalSince1970: 100)
        _ = try await store.enqueue(
            request: makeRequest(id: "expired"),
            ownerEmail: "user@example.com",
            retryAfterSeconds: 5,
            at: created
        )

        let beforeExpiry = try await store.all(
            at: created.addingTimeInterval(24 * 60 * 60 - 1)
        )
        XCTAssertEqual(beforeExpiry.map(\.requestID), ["expired"])

        let atExpiry = try await store.all(
            at: created.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertTrue(atExpiry.isEmpty)
    }

    func testReadyEntriesAreOwnerScopedAndSuccessfulRemovalPersists() async throws {
        let store = PendingManagedAnalysisStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_000)
        _ = try await store.enqueue(
            request: makeRequest(id: "ready"),
            ownerEmail: "first@example.com",
            retryAfterSeconds: 0,
            at: now
        )
        _ = try await store.enqueue(
            request: makeRequest(id: "other-owner"),
            ownerEmail: "other@example.com",
            retryAfterSeconds: 0,
            at: now
        )

        let ready = try await store.ready(
            ownerEmail: "FIRST@example.com",
            limit: 3,
            at: now.addingTimeInterval(5)
        )
        XCTAssertEqual(ready.map(\.requestID), ["ready"])

        try await store.remove(
            requestID: "ready",
            ownerEmail: "first@example.com",
            at: now.addingTimeInterval(5)
        )
        let reloaded = PendingManagedAnalysisStore(fileURL: fileURL)
        let remaining = try await reloaded.all(at: now.addingTimeInterval(5))
        XCTAssertEqual(remaining.map(\.requestID), ["other-owner"])
    }

    func testRetryBackoffHonorsServerDelayAndCapsAtFiveMinutes() async throws {
        let store = PendingManagedAnalysisStore(fileURL: fileURL)
        var now = Date(timeIntervalSince1970: 1_000)
        _ = try await store.enqueue(
            request: makeRequest(id: "request-1"),
            ownerEmail: "user@example.com",
            retryAfterSeconds: 1,
            at: now
        )

        let initial = try await store.next(ownerEmail: "user@example.com", at: now)
        var entry = try XCTUnwrap(initial)
        XCTAssertEqual(entry.nextRetryAt, now.addingTimeInterval(5))

        now = entry.nextRetryAt
        let firstReschedule = try await store.reschedule(
            requestID: entry.requestID,
            ownerEmail: entry.ownerEmail,
            retryAfterSeconds: 45,
            at: now
        )
        entry = try XCTUnwrap(firstReschedule)
        XCTAssertEqual(entry.retryCount, 2)
        XCTAssertEqual(entry.nextRetryAt, now.addingTimeInterval(45))

        for _ in 0..<10 {
            now = entry.nextRetryAt
            let rescheduled = try await store.reschedule(
                requestID: entry.requestID,
                ownerEmail: entry.ownerEmail,
                retryAfterSeconds: nil,
                at: now
            )
            entry = try XCTUnwrap(rescheduled)
        }
        XCTAssertEqual(entry.nextRetryAt.timeIntervalSince(now), 300)
    }

    func testMalformedFileRecoversToEmptyAndCanPersistAgain() async throws {
        try Data("{not-json".utf8).write(to: fileURL)
        let store = PendingManagedAnalysisStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_000)

        let recovered = try await store.all(at: now)
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        _ = try await store.enqueue(
            request: makeRequest(id: "after-recovery"),
            ownerEmail: "user@example.com",
            retryAfterSeconds: 0,
            at: now
        )
        let reloaded = PendingManagedAnalysisStore(fileURL: fileURL)
        let entries = try await reloaded.all(at: now)
        XCTAssertEqual(entries.map(\.requestID), ["after-recovery"])
    }

    func testLogoutPrimitiveRemovesSensitivePayloadSynchronously() throws {
        try Data("private transcript and thumbnail".utf8).write(to: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        PendingManagedAnalysisStore.removeFileSynchronously(at: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeRequest(
        id: String,
        title: String = "Test video"
    ) -> ManagedAnalysisCreateRequest {
        ManagedAnalysisCreateRequest(
            idempotencyKey: id,
            youtubeId: "abcdefghijk",
            sourceUrl: "https://www.youtube.com/watch?v=abcdefghijk",
            title: title,
            durationSec: 60,
            cues: [.init(index: 0, time: 0, endTime: 1, text: "Hello")],
            transcriptSrt: "1\n00:00:00,000 --> 00:00:01,000\nHello",
            thumbData: nil
        )
    }
}
