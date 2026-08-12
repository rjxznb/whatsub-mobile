import XCTest
@testable import whatsub_mobile

final class PendingManagedAnalysisCoordinatorTests: XCTestCase {
    private actor Client: ManagedAnalysisClientProtocol {
        private(set) var requestIDs: [String] = []
        private(set) var cancelledJobIDs: [String] = []
        private var createErrors: [ManagedAnalysisClientError]

        init(createErrors: [ManagedAnalysisClientError] = []) {
            self.createErrors = createErrors
        }

        func createJob(
            _ request: ManagedAnalysisCreateRequest,
            token: String
        ) async throws -> ManagedAnalysisJob {
            requestIDs.append(request.idempotencyKey)
            if !createErrors.isEmpty {
                throw createErrors.removeFirst()
            }
            return ManagedAnalysisJob(
                jobId: "job-\(request.idempotencyKey)",
                status: .queued,
                tier: .pro,
                createdAt: 1,
                updatedAt: 1,
                completedCues: 0,
                totalCues: 1,
                tokensIn: 0,
                tokensOut: 0,
                errorCode: nil,
                resultEntryId: "entry-\(request.idempotencyKey)"
            )
        }

        func job(id: String, token: String) async throws -> ManagedAnalysisJob {
            throw ManagedAnalysisClientError.notFound
        }
        func jobs(token: String) async throws -> [ManagedAnalysisJob] { [] }
        func results(id: String, afterBatch: Int, token: String) async throws -> ManagedAnalysisResultsPage {
            throw ManagedAnalysisClientError.notFound
        }
        func cancel(id: String, token: String) async throws -> ManagedAnalysisJob {
            cancelledJobIDs.append(id)
            return ManagedAnalysisJob(
                jobId: id, status: .cancelled, tier: .pro,
                createdAt: 1, updatedAt: 2, completedCues: 0, totalCues: 1,
                tokensIn: 0, tokensOut: 0, errorCode: nil,
                resultEntryId: nil
            )
        }
        func resume(id: String, token: String) async throws -> ManagedAnalysisJob {
            throw ManagedAnalysisClientError.notFound
        }
    }

    func testColdActivationProcessesEveryPersistedSubmissionWithoutImportView() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 10_000)
        for id in ["first", "second"] {
            _ = try await fixture.store.enqueue(
                request: request(id),
                ownerEmail: "user@example.com",
                retryAfterSeconds: 0,
                at: now.addingTimeInterval(-10)
            )
        }
        let client = Client()
        let coordinator = PendingManagedAnalysisCoordinator(
            client: client,
            store: fixture.store,
            now: { now },
            sleeper: { _ in }
        )

        await coordinator.activate(token: "token", email: "USER@example.com")
        await eventually { await client.requestIDs.count == 2 }

        let submitted = await client.requestIDs
        XCTAssertEqual(submitted, ["first", "second"])
        let remaining = try await fixture.store.all(at: now)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLogoutClearRemovesPrivatePayloadBeforeAnyFutureActivation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 20_000)
        _ = try await fixture.store.enqueue(
            request: request("private"),
            ownerEmail: "user@example.com",
            retryAfterSeconds: 300,
            at: now
        )
        let client = Client()
        let coordinator = PendingManagedAnalysisCoordinator(
            client: client,
            store: fixture.store,
            now: { now },
            sleeper: { _ in try await Task.sleep(nanoseconds: UInt64.max) }
        )

        await coordinator.activate(token: "token", email: "user@example.com")
        await coordinator.clear(ownerEmail: "user@example.com")

        let remaining = try await fixture.store.all(at: now)
        XCTAssertTrue(remaining.isEmpty)
        let submitted = await client.requestIDs
        XCTAssertTrue(submitted.isEmpty)
    }

    func testCancelledObserverDoesNotLeaveSuspendedContinuation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let coordinator = PendingManagedAnalysisCoordinator(
            client: Client(),
            store: fixture.store,
            sleeper: { _ in }
        )
        let observer = Task {
            await coordinator.waitForResolution(
                requestID: "cancel-observer",
                ownerEmail: "user@example.com"
            )
        }
        await Task.yield()

        observer.cancel()
        let resolution = await observer.value

        XCTAssertEqual(
            resolution,
            .cancelled(
                requestID: "cancel-observer",
                ownerEmail: "user@example.com"
            )
        )
    }

    func testCancellingPendingRowInvalidatesRunnerThatAlreadyReadIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sleeper = GateSleeper()
        let client = Client()
        let coordinator = PendingManagedAnalysisCoordinator(
            client: client,
            store: fixture.store,
            sleeper: { seconds in try await sleeper.sleep(seconds) }
        )

        _ = try await coordinator.enqueue(
            request: request("cancel-before-submit"),
            ownerEmail: "user@example.com",
            retryAfterSeconds: 5,
            token: "token"
        )
        await eventually { await sleeper.calls == 1 }
        await coordinator.cancel(
            requestID: "cancel-before-submit",
            ownerEmail: "user@example.com"
        )
        await sleeper.release()
        for _ in 0..<20 { await Task.yield() }

        let submitted = await client.requestIDs
        XCTAssertTrue(submitted.isEmpty)
    }

    func testTransientNetworkAndServerFailuresRemainQueuedUntilAccepted() async throws {
        for transient in [
            ManagedAnalysisClientError.network("offline"),
            .server(
                status: 503,
                code: "temporary",
                diagnosticCode: nil,
                diagnosticId: nil
            )
        ] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let client = Client(createErrors: [transient])
            let coordinator = PendingManagedAnalysisCoordinator(
                client: client,
                store: fixture.store,
                sleeper: { _ in }
            )

            _ = try await coordinator.enqueue(
                request: request("transient"),
                ownerEmail: "user@example.com",
                retryAfterSeconds: 0,
                token: "token"
            )
            await eventually { await client.requestIDs.count == 2 }

            let submitted = await client.requestIDs
            XCTAssertEqual(submitted, ["transient", "transient"])
            let remaining = try await fixture.store.all()
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    private actor GateSleeper {
        private(set) var calls = 0
        private var continuation: CheckedContinuation<Void, Never>?

        func sleep(_: TimeInterval) async throws {
            calls += 1
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private struct Fixture {
        let store: PendingManagedAnalysisStore
        let directory: URL
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return Fixture(
            store: PendingManagedAnalysisStore(
                fileURL: directory.appendingPathComponent("pending.json")
            ),
            directory: directory
        )
    }

    private func request(_ id: String) -> ManagedAnalysisCreateRequest {
        ManagedAnalysisCreateRequest(
            idempotencyKey: id,
            youtubeId: "abcdefghijk",
            sourceUrl: "https://youtu.be/abcdefghijk",
            title: id,
            durationSec: 60,
            cues: [.init(index: 0, time: 0, endTime: 1, text: "Hello")],
            transcriptSrt: "Hello",
            thumbData: nil
        )
    }

    private func eventually(
        _ predicate: @escaping () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
