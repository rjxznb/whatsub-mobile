import XCTest
@testable import whatsub_mobile

@MainActor
final class ImportManagedAnalysisTests: XCTestCase {

    private actor ClientSpy: ManagedAnalysisClientProtocol {
        private(set) var createCalls = 0
        private(set) var lastRequest: ManagedAnalysisCreateRequest?
        private(set) var idempotencyKeys: [String] = []
        private var createStatus: ManagedAnalysisJobStatus = .queued

        func setCreateStatus(_ status: ManagedAnalysisJobStatus) {
            createStatus = status
        }

        func createJob(
            _ request: ManagedAnalysisCreateRequest,
            token: String
        ) async throws -> ManagedAnalysisJob {
            createCalls += 1
            lastRequest = request
            idempotencyKeys.append(request.idempotencyKey)
            return Self.makeJob(status: createStatus)
        }

        func job(id: String, token: String) async throws -> ManagedAnalysisJob { Self.job }
        func jobs(token: String) async throws -> [ManagedAnalysisJob] { [Self.job] }
        func cancel(id: String, token: String) async throws -> ManagedAnalysisJob {
            Self.makeJob(status: .cancelled)
        }
        func resume(id: String, token: String) async throws -> ManagedAnalysisJob { Self.job }

        static let job = makeJob(status: .queued)
        static func makeJob(status: ManagedAnalysisJobStatus) -> ManagedAnalysisJob {
            ManagedAnalysisJob(
                jobId: "job-1", status: status, tier: .free,
                createdAt: 1, updatedAt: 1, completedCues: 0, totalCues: 1,
                tokensIn: 0, tokensOut: 0, errorCode: nil, resultEntryId: nil
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
        refreshedDuration: Int? = nil
    ) -> ImportViewModel {
        let cue = Cue(index: 0, time: 0, endTime: 1, text: "Hello")
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
            localAnalyzer: { cues, _, _, progress, _ in
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
            localAnalyzer: { cues, _, _, progress, _ in
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
}
