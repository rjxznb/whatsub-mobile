import XCTest
@testable import whatsub_mobile

@MainActor
final class ImportManagedAnalysisTests: XCTestCase {

    private actor ClientSpy: ManagedAnalysisClientProtocol {
        private(set) var createCalls = 0
        private(set) var lastRequest: ManagedAnalysisCreateRequest?
        private(set) var idempotencyKeys: [String] = []
        private var createStatus: ManagedAnalysisJobStatus = .queued
        private var createErrors: [ManagedAnalysisClientError] = []
        private var resultEntryID: String?

        func setCreateStatus(_ status: ManagedAnalysisJobStatus) {
            createStatus = status
        }

        func enqueueCreateError(_ error: ManagedAnalysisClientError) {
            createErrors.append(error)
        }

        func setResultEntryID(_ entryID: String?) {
            resultEntryID = entryID
        }

        func createJob(
            _ request: ManagedAnalysisCreateRequest,
            token: String
        ) async throws -> ManagedAnalysisJob {
            createCalls += 1
            lastRequest = request
            idempotencyKeys.append(request.idempotencyKey)
            if !createErrors.isEmpty {
                throw createErrors.removeFirst()
            }
            return Self.makeJob(status: createStatus, resultEntryID: resultEntryID)
        }

        func job(id: String, token: String) async throws -> ManagedAnalysisJob { Self.job }
        func jobs(token: String) async throws -> [ManagedAnalysisJob] { [Self.job] }
        func results(
            id: String,
            afterBatch: Int,
            token: String
        ) async throws -> ManagedAnalysisResultsPage {
            throw ManagedAnalysisClientError.notFound
        }
        func cancel(id: String, token: String) async throws -> ManagedAnalysisJob {
            Self.makeJob(status: .cancelled)
        }
        func resume(id: String, token: String) async throws -> ManagedAnalysisJob { Self.job }

        static let job = makeJob(status: .queued)
        static func makeJob(
            status: ManagedAnalysisJobStatus,
            resultEntryID: String? = nil
        ) -> ManagedAnalysisJob {
            ManagedAnalysisJob(
                jobId: "job-1", status: status, tier: .free,
                createdAt: 1, updatedAt: 1, completedCues: 0, totalCues: 1,
                tokensIn: 0, tokensOut: 0, errorCode: nil,
                resultEntryId: resultEntryID
            )
        }
    }

    private actor LocalAnalyzerSpy {
        enum StubError: Error { case stopBeforeSync }
        private(set) var calls = 0
        let shouldFail: Bool

        init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

        func analyze(_ cues: [Cue], _ progress: @escaping (Int, Int) -> Void) async throws -> AnalysisJson {
            calls += 1
            if shouldFail { throw StubError.stopBeforeSync }
            progress(1, 1)
            return AnalysisJson.assembled(subtitles: cues, keyPhrases: [])
        }
    }

    private actor ExtractionGate {
        private var firstContinuation: CheckedContinuation<Void, Never>?
        private(set) var firstStarted = false

        func extract(videoId: String) async -> CaptionExtractionResult {
            if videoId == "abcdefghijk" {
                firstStarted = true
                await withCheckedContinuation { continuation in
                    firstContinuation = continuation
                }
            }
            return CaptionExtractionResult(
                cues: [Cue(index: 0, time: 0, endTime: 1, text: videoId)],
                durationSec: 60
            )
        }

        func releaseFirst() {
            firstContinuation?.resume()
            firstContinuation = nil
        }
    }

    private func settings(managed: Bool) -> LlmSettings {
        var value = LlmSettings()
        value.useManagedRelay = managed
        if !managed {
            value.baseUrl = "https://provider.example/v1"
            value.apiKey = "key"
            value.model = "model"
        }
        return value
    }

    private func makeVM(
        client: ClientSpy,
        analyzer: LocalAnalyzerSpy,
        managed: Bool = true,
        entitlement: ManagedEntitlementState,
        duration: Int?,
        refreshedDuration: Int? = nil,
        pendingStore: PendingManagedAnalysisStore = PendingManagedAnalysisStore(),
        now: @escaping () -> Date = Date.init,
        retrySleep: @escaping (TimeInterval) async throws -> Void = { _ in
            throw CancellationError()
        }
    ) -> ImportViewModel {
        let cue = Cue(index: 0, time: 0, endTime: 1, text: "Hello")
        let pendingCoordinator = PendingManagedAnalysisCoordinator(
            client: client,
            store: pendingStore,
            now: now,
            sleeper: retrySleep
        )
        return ImportViewModel(
            managedClient: client,
            entitlementRefresher: { _ in entitlement },
            settingsProvider: { self.settings(managed: managed) },
            captionExtractor: { _, _ in
                CaptionExtractionResult(cues: [cue], durationSec: duration)
            },
            titleFetcher: { _ in "Test video" },
            thumbnailFetcher: { _ in nil },
            durationRefresher: { _ in refreshedDuration },
            pendingCoordinator: pendingCoordinator,
            localAnalyzer: { cues, _, _, _, progress, _ in
                try await analyzer.analyze(cues, progress)
            }
        )
    }

    func testFreshFreeOverTwentyMinutesStopsBeforeJobCreation() async {
        let client = ClientSpy()
        let analyzer = LocalAnalyzerSpy()
        let vm = makeVM(
            client: client, analyzer: analyzer,
            entitlement: .freshFree, duration: 1201
        )

        await vm.run(
            urlOrId: "https://www.youtube.com/watch?v=abcdefghijk",
            token: "t"
        )

        let createCalls = await client.createCalls
        XCTAssertEqual(createCalls, 0)
        guard case .managedPolicy(.videoTooLong(let duration, let limit)) = vm.state else {
            XCTFail("expected local free duration policy")
            return
        }
        XCTAssertEqual(duration, 1201)
        XCTAssertEqual(limit, 1200)
    }

    func testUnknownEntitlementLetsBackendCorrectStaleFreeState() async {
        let client = ClientSpy()
        let analyzer = LocalAnalyzerSpy()
        let vm = makeVM(
            client: client, analyzer: analyzer,
            entitlement: .unknown, duration: 1201
        )

        await vm.run(
            urlOrId: "https://www.youtube.com/watch?v=abcdefghijk",
            token: "t"
        )

        let createCalls = await client.createCalls
        XCTAssertEqual(createCalls, 1)
        guard case .managedJob(let job) = vm.state else {
            XCTFail("expected durable managed job")
            return
        }
        XCTAssertEqual(job.jobId, "job-1")
    }

    func testManagedSubmissionDoesNotRunLocalAnalysisEngine() async {
        let client = ClientSpy()
        let analyzer = LocalAnalyzerSpy()
        let vm = makeVM(
            client: client, analyzer: analyzer,
            entitlement: .freshPro, duration: 86_400
        )

        await vm.run(
            urlOrId: "https://www.youtube.com/watch?v=abcdefghijk",
            token: "t"
        )

        let createCalls = await client.createCalls
        let analyzerCalls = await analyzer.calls
        XCTAssertEqual(createCalls, 1)
        XCTAssertEqual(analyzerCalls, 0)
        let request = await client.lastRequest
        XCTAssertEqual(request?.durationSec, 86_400)
        XCTAssertEqual(request?.cues.count, 1)
    }

    func testManagedUnknownDurationStopsBeforeJobCreation() async {
        let client = ClientSpy()
        let analyzer = LocalAnalyzerSpy()
        let vm = makeVM(
            client: client, analyzer: analyzer,
            entitlement: .freshPro, duration: nil
        )

        await vm.run(
            urlOrId: "https://www.youtube.com/watch?v=abcdefghijk",
            token: "t"
        )

        let createCalls = await client.createCalls
        XCTAssertEqual(createCalls, 0)
        guard case .managedPolicy(.durationUnknown) = vm.state else {
            XCTFail("expected duration unknown policy")
            return
        }
    }

    func testBYOKVideoHasNoProductDurationCapAndNeverCreatesManagedJob() async {
        let client = ClientSpy()
        let analyzer = LocalAnalyzerSpy(shouldFail: true)
        let vm = makeVM(
            client: client, analyzer: analyzer, managed: false,
            entitlement: .freshFree, duration: 86_400
        )

        await vm.run(
            urlOrId: "https://www.youtube.com/watch?v=abcdefghijk",
            token: "t"
        )

        let createCalls = await client.createCalls
        let analyzerCalls = await analyzer.calls
        XCTAssertEqual(createCalls, 0)
        XCTAssertEqual(analyzerCalls, 1)
    }

    func testManagedTransportRetryKeepsIdempotencyButExplicitCancelRotatesIt() async {
        let client = ClientSpy()
        let analyzer = LocalAnalyzerSpy()
        let vm = makeVM(
            client: client, analyzer: analyzer,
            entitlement: .freshPro, duration: 120
        )

        await vm.run(
            urlOrId: "https://www.youtube.com/watch?v=abcdefghijk",
            token: "t"
        )
        await vm.retryManagedSubmission(token: "t")
        let beforeCancel = await client.idempotencyKeys
        XCTAssertEqual(beforeCancel.count, 2)
        XCTAssertEqual(beforeCancel[0], beforeCancel[1])

        await vm.cancelManagedJob(token: "t")
        await vm.retryManagedSubmission(token: "t")
        let afterCancel = await client.idempotencyKeys
        XCTAssertEqual(afterCancel.count, 3)
        XCTAssertNotEqual(afterCancel[1], afterCancel[2])
    }

    func testDurationRetryKeepsCachedCuesAndFetchesOnlyMetadata() async {
        let client = ClientSpy()
        let analyzer = LocalAnalyzerSpy()
        let vm = makeVM(
            client: client, analyzer: analyzer,
            entitlement: .freshPro, duration: nil, refreshedDuration: 600
        )

        await vm.run(
            urlOrId: "https://www.youtube.com/watch?v=abcdefghijk",
            token: "t"
        )
        XCTAssertEqual(vm.rawCues.first?.text, "Hello")

        await vm.retryManagedSubmission(token: "t", refreshDuration: true)

        XCTAssertEqual(vm.rawCues.first?.text, "Hello")
        XCTAssertEqual(vm.videoDurationSec, 600)
        let createCalls = await client.createCalls
        XCTAssertEqual(createCalls, 1)
    }

    func testPersistedAttemptSurvivesViewModelRecreation() async {
        let firstClient = ClientSpy()
        let firstVM = makeVM(
            client: firstClient, analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro, duration: 120
        )
        await firstVM.run(urlOrId: "abcdefghijk", token: "t")
        let firstRequest = await firstClient.lastRequest
        let firstKey = firstRequest?.idempotencyKey

        let secondClient = ClientSpy()
        let secondVM = makeVM(
            client: secondClient, analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro, duration: 120
        )
        await secondVM.run(urlOrId: "abcdefghijk", token: "t")
        let secondRequest = await secondClient.lastRequest
        let secondKey = secondRequest?.idempotencyKey

        XCTAssertNotNil(firstKey)
        XCTAssertEqual(firstKey, secondKey)
    }

    func testTerminalFailedResponseRotatesAttemptForExplicitRetry() async {
        let client = ClientSpy()
        await client.setCreateStatus(.failed)
        let vm = makeVM(
            client: client, analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro, duration: 120
        )

        await vm.run(urlOrId: "abcdefghijk", token: "t")
        await client.setCreateStatus(.queued)
        await vm.retryManagedSubmission(token: "t")

        let keys = await client.idempotencyKeys
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
    }

    func testCancelledOldRunCannotOverwriteNewRunState() async {
        let client = ClientSpy()
        let analyzer = LocalAnalyzerSpy()
        let gate = ExtractionGate()
        let vm = ImportViewModel(
            managedClient: client,
            entitlementRefresher: { _ in .freshPro },
            settingsProvider: { self.settings(managed: true) },
            captionExtractor: { videoId, _ in await gate.extract(videoId: videoId) },
            titleFetcher: { id in id },
            thumbnailFetcher: { _ in nil },
            durationRefresher: { _ in 60 },
            localAnalyzer: { cues, _, _, _, progress, _ in
                try await analyzer.analyze(cues, progress)
            }
        )

        vm.start(urlOrId: "abcdefghijk", token: "t")
        for _ in 0..<200 {
            if await gate.firstStarted { break }
            await Task.yield()
        }
        vm.start(urlOrId: "lmnopqrstuv", token: "t")
        for _ in 0..<200 {
            if await client.createCalls > 0 { break }
            await Task.yield()
        }
        await gate.releaseFirst()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(vm.videoId, "lmnopqrstuv")
        guard case .managedJob = vm.state else {
            XCTFail("old cancelled run overwrote the new durable job state")
            return
        }
    }

    private actor RetrySleeper {
        private(set) var calls = 0
        private var continuation: CheckedContinuation<Void, Error>?

        func sleep(_: TimeInterval) async throws {
            calls += 1
            if calls == 1 {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testRetryableQueueLimitPersistsPreparedRequestWithoutCredentials() async throws {
        let fixture = try makePendingStoreFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_000)
        let client = ClientSpy()
        await client.enqueueCreateError(.queueLimit)
        let vm = makeVM(
            client: client,
            analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro,
            duration: 60,
            pendingStore: fixture.store,
            now: { now }
        )

        await vm.run(
            urlOrId: "abcdefghijk",
            token: "secret-session-token",
            email: "User@example.com"
        )

        let entries = try await fixture.store.all(at: now)
        XCTAssertEqual(entries.count, 1)
        let pending = try XCTUnwrap(entries.first)
        XCTAssertEqual(pending.requestID, pending.request.idempotencyKey)
        XCTAssertEqual(pending.ownerEmail, "user@example.com")
        let encoded = String(data: try JSONEncoder().encode(pending), encoding: .utf8)
        let storedJSON = try XCTUnwrap(encoded)
        XCTAssertFalse(storedJSON.contains("secret-session-token"))
        XCTAssertFalse(storedJSON.localizedCaseInsensitiveContains("apiKey"))
        guard case .pendingManagedSubmission(let requestID, let retryAt) = vm.state else {
            XCTFail("expected a quiet pending-submission state")
            return
        }
        XCTAssertEqual(requestID, pending.requestID)
        XCTAssertEqual(retryAt, pending.nextRetryAt)
    }

    func testOnlyRetryableServerBusyIsPersisted() async throws {
        let retryableFixture = try makePendingStoreFixture()
        defer { retryableFixture.cleanup() }
        let retryableClient = ClientSpy()
        await retryableClient.enqueueCreateError(.serverBusy(retryable: true))
        let retryableVM = makeVM(
            client: retryableClient,
            analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro,
            duration: 60,
            pendingStore: retryableFixture.store
        )
        await retryableVM.run(
            urlOrId: "abcdefghijk",
            token: "t",
            email: "user@example.com"
        )
        let retryableEntries = try await retryableFixture.store.all()
        XCTAssertEqual(retryableEntries.count, 1)

        let permanentFixture = try makePendingStoreFixture()
        defer { permanentFixture.cleanup() }
        let permanentClient = ClientSpy()
        await permanentClient.enqueueCreateError(.serverBusy(retryable: false))
        let permanentVM = makeVM(
            client: permanentClient,
            analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro,
            duration: 60,
            pendingStore: permanentFixture.store
        )
        await permanentVM.run(
            urlOrId: "abcdefghijk",
            token: "t",
            email: "user@example.com"
        )
        let permanentEntries = try await permanentFixture.store.all()
        XCTAssertTrue(permanentEntries.isEmpty)
        guard case .managedPolicy(.serverBusy) = permanentVM.state else {
            XCTFail("non-retryable server_busy must be shown immediately")
            return
        }
    }

    func testAuthenticationQuotaValidationAndPermanentErrorsAreNotPersisted() async throws {
        let cases: [(ManagedAnalysisClientError, (ImportViewModel.State) -> Bool)] = [
            (.unauthorized, { if case .error = $0 { return true }; return false }),
            (.freeUsedUp, { if case .managedPolicy(.freeUsedUp) = $0 { return true }; return false }),
            (.quotaExceeded, { if case .managedPolicy(.quotaExceeded) = $0 { return true }; return false }),
            (.videoTooLong, { if case .managedPolicy(.videoTooLong) = $0 { return true }; return false }),
            (
                .server(status: 400, code: "invalid_input", diagnosticCode: nil, diagnosticId: nil),
                { if case .error = $0 { return true }; return false }
            ),
            (.upstreamUnavailable, { if case .managedPolicy(.upstreamUnavailable) = $0 { return true }; return false })
        ]

        for (error, isExpectedState) in cases {
            let fixture = try makePendingStoreFixture()
            defer { fixture.cleanup() }
            let client = ClientSpy()
            await client.enqueueCreateError(error)
            let vm = makeVM(
                client: client,
                analyzer: LocalAnalyzerSpy(),
                entitlement: .freshPro,
                duration: 60,
                pendingStore: fixture.store
            )

            await vm.run(
                urlOrId: "abcdefghijk",
                token: "t",
                email: "user@example.com"
            )

            XCTAssertTrue(isExpectedState(vm.state), "wrong immediate state for \(error)")
            let pendingEntries = try await fixture.store.all()
            XCTAssertTrue(pendingEntries.isEmpty)
        }
    }

    func testForegroundRetryUsesSameRequestIDAndCreatesAtMostOneJob() async throws {
        let fixture = try makePendingStoreFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 2_000)
        let client = ClientSpy()
        await client.enqueueCreateError(.queueLimit)
        let vm = makeVM(
            client: client,
            analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro,
            duration: 60,
            pendingStore: fixture.store,
            now: { now },
            retrySleep: { _ in }
        )

        await vm.run(
            urlOrId: "abcdefghijk",
            token: "t",
            email: "user@example.com"
        )
        vm.setSceneActive(true, token: "t", email: "user@example.com")
        vm.setSceneActive(true, token: "t", email: "user@example.com")

        await eventually {
            await client.createCalls == 2
        }
        let keys = await client.idempotencyKeys
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])
        let remaining = try await fixture.store.all(at: now)
        XCTAssertTrue(remaining.isEmpty)
        guard case .managedJob(let job) = vm.state else {
            XCTFail("successful retry must enter the existing managed job flow")
            return
        }
        XCTAssertEqual(job.jobId, "job-1")
    }

    func testUserCanCancelPendingAutomaticSubmission() async throws {
        let fixture = try makePendingStoreFixture()
        defer { fixture.cleanup() }
        let client = ClientSpy()
        await client.enqueueCreateError(.queueLimit)
        let vm = makeVM(
            client: client,
            analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro,
            duration: 60,
            pendingStore: fixture.store
        )
        await vm.run(
            urlOrId: "abcdefghijk",
            token: "t",
            email: "user@example.com"
        )

        await vm.cancelPendingManagedSubmission()

        let remaining = try await fixture.store.all()
        XCTAssertTrue(remaining.isEmpty)
        guard case .idle = vm.state else {
            XCTFail("cancelling pending intent should return to idle")
            return
        }
    }

    func testClosingImportViewDoesNotStopAppOwnedRetry() async throws {
        let fixture = try makePendingStoreFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_000)
        let client = ClientSpy()
        await client.enqueueCreateError(.queueLimit)
        let sleeper = RetrySleeper()
        let vm = makeVM(
            client: client,
            analyzer: LocalAnalyzerSpy(),
            entitlement: .freshPro,
            duration: 60,
            pendingStore: fixture.store,
            now: { now },
            retrySleep: { seconds in try await sleeper.sleep(seconds) }
        )

        await vm.run(
            urlOrId: "abcdefghijk",
            token: "t",
            email: "user@example.com"
        )
        await eventually { await sleeper.calls == 1 }
        vm.cancelWork()

        // Closing the view only cancels its observation. The App-owned
        // coordinator remains alive and submits when its delay elapses.
        await sleeper.release()
        await eventually { await client.createCalls == 2 }
        let keys = await client.idempotencyKeys
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])
    }

    func testClosingImportViewReleasesItsPendingObserver() async throws {
        let fixture = try makePendingStoreFixture()
        defer { fixture.cleanup() }
        let client = ClientSpy()
        await client.enqueueCreateError(.queueLimit)
        weak var releasedViewModel: ImportViewModel?

        do {
            let viewModel = makeVM(
                client: client,
                analyzer: LocalAnalyzerSpy(),
                entitlement: .freshPro,
                duration: 60,
                pendingStore: fixture.store
            )
            releasedViewModel = viewModel
            await viewModel.run(
                urlOrId: "abcdefghijk",
                token: "t",
                email: "user@example.com"
            )
            viewModel.cancelWork()
        }

        await eventually { releasedViewModel == nil }
        XCTAssertNil(releasedViewModel)
    }

    private struct PendingStoreFixture {
        let store: PendingManagedAnalysisStore
        let directory: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makePendingStoreFixture() throws -> PendingStoreFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return PendingStoreFixture(
            store: PendingManagedAnalysisStore(
                fileURL: directory.appendingPathComponent("pending.json")
            ),
            directory: directory
        )
    }

    private func makePendingRequest(id: String) -> ManagedAnalysisCreateRequest {
        ManagedAnalysisCreateRequest(
            idempotencyKey: id,
            youtubeId: "abcdefghijk",
            sourceUrl: "https://www.youtube.com/watch?v=abcdefghijk",
            title: "Persisted video",
            durationSec: 60,
            cues: [.init(index: 0, time: 0, endTime: 1, text: "Hello")],
            transcriptSrt: "1\n00:00:00,000 --> 00:00:01,000\nHello",
            thumbData: nil
        )
    }

    private func eventually(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition was not satisfied", file: file, line: line)
    }
}
