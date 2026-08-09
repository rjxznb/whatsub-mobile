import XCTest
@testable import whatsub_mobile

final class LibraryManagedAnalysisTests: XCTestCase {
    private actor API: LibraryDesktopReplacementAPI, ManagedAnalysisClientProtocol {
        private var detailQueue: [LibraryEntryDetail]
        private var resultQueue: [ManagedAnalysisResultsPage]
        private var detailCallCount = 0
        private let failingDetailCalls: Set<Int>
        private var resultCallCount = 0
        private let failingResultCalls: Set<Int>
        private(set) var requestedCursors: [Int] = []
        private var cancelError: ManagedAnalysisClientError?
        private var cancelResponse: ManagedAnalysisJob?
        private var jobQueue: [ManagedAnalysisJob]
        private(set) var cancelledJobIDs: [String] = []
        var listedJobs: [ManagedAnalysisJob]

        init(
            details: [LibraryEntryDetail],
            jobs: [ManagedAnalysisJob],
            results: [ManagedAnalysisResultsPage],
            failingDetailCalls: Set<Int> = [],
            failingResultCalls: Set<Int> = [],
            cancelResponse: ManagedAnalysisJob? = nil,
            cancelError: ManagedAnalysisClientError? = nil,
            jobResponses: [ManagedAnalysisJob] = []
        ) {
            detailQueue = details
            listedJobs = jobs
            resultQueue = results
            self.failingDetailCalls = failingDetailCalls
            self.failingResultCalls = failingResultCalls
            self.cancelResponse = cancelResponse
            self.cancelError = cancelError
            jobQueue = jobResponses
        }

        func cursors() -> [Int] { requestedCursors }
        func cancelCalls() -> [String] { cancelledJobIDs }

        func libraryEntry(id: String, token: String) async throws -> LibraryEntryDetail {
            detailCallCount += 1
            if failingDetailCalls.contains(detailCallCount) {
                throw ManagedAnalysisClientError.network("temporary")
            }
            guard !detailQueue.isEmpty else { throw ManagedAnalysisClientError.notFound }
            if detailQueue.count == 1 { return detailQueue[0] }
            return detailQueue.removeFirst()
        }

        func listImportQueue(token: String) async throws -> (items: [ImportQueueItem], desktopSeenSecondsAgo: Int?) {
            ([], nil)
        }

        func enqueueReplacement(
            url: String,
            targetLibraryEntryId: String,
            token: String
        ) async throws -> EnqueueImportResponse {
            throw ManagedAnalysisClientError.server(
                status: 500,
                code: nil,
                diagnosticCode: nil,
                diagnosticId: nil
            )
        }

        func createJob(
            _ request: ManagedAnalysisCreateRequest,
            token: String
        ) async throws -> ManagedAnalysisJob { listedJobs[0] }

        func job(id: String, token: String) async throws -> ManagedAnalysisJob {
            if !jobQueue.isEmpty { return jobQueue.removeFirst() }
            guard let first = listedJobs.first else { throw ManagedAnalysisClientError.notFound }
            return first
        }
        func jobs(token: String) async throws -> [ManagedAnalysisJob] { listedJobs }

        func results(
            id: String,
            afterBatch: Int,
            token: String
        ) async throws -> ManagedAnalysisResultsPage {
            requestedCursors.append(afterBatch)
            resultCallCount += 1
            if failingResultCalls.contains(resultCallCount) {
                throw ManagedAnalysisClientError.network("temporary")
            }
            guard !resultQueue.isEmpty else { throw ManagedAnalysisClientError.notFound }
            return resultQueue.removeFirst()
        }

        func cancel(id: String, token: String) async throws -> ManagedAnalysisJob {
            cancelledJobIDs.append(id)
            if let cancelError { throw cancelError }
            guard let cancelResponse else {
                throw ManagedAnalysisClientError.invalidResponse("missing cancel response")
            }
            return cancelResponse
        }

        func resume(id: String, token: String) async throws -> ManagedAnalysisJob {
            let old = listedJobs[0]
            let resumed = ManagedAnalysisJob(
                jobId: old.jobId, status: .queued, tier: old.tier,
                createdAt: old.createdAt, updatedAt: old.updatedAt + 1,
                completedCues: old.completedCues, totalCues: old.totalCues,
                tokensIn: old.tokensIn, tokensOut: old.tokensOut,
                errorCode: nil, resultEntryId: old.resultEntryId
            )
            listedJobs = [resumed]
            return resumed
        }
    }

    private func cue(_ index: Int, translation: String = "") -> Cue {
        Cue(
            index: index,
            time: Double(index),
            endTime: Double(index) + 0.5,
            text: "Cue \(index)",
            translation: translation
        )
    }

    private func entry(translations: [String]) -> LibraryEntryDetail {
        let cues = translations.enumerated().map { cue($0.offset, translation: $0.element) }
        return LibraryEntryDetail(
            id: "entry-1",
            youtubeId: "abcdefghijk",
            sourceUrl: "https://youtu.be/abcdefghijk",
            title: "Progressive video",
            durationSec: 30,
            transcriptSrt: "captions",
            analysisJson: .assembled(subtitles: cues, keyPhrases: []),
            videoUrl: nil,
            audioUrl: nil
        )
    }

    private func job(
        status: ManagedAnalysisJobStatus = .running,
        completedCues: Int = 0
    ) -> ManagedAnalysisJob {
        ManagedAnalysisJob(
            jobId: "job-1", status: status, tier: .pro,
            createdAt: 1, updatedAt: 2, completedCues: completedCues, totalCues: 2,
            tokensIn: 0, tokensOut: 0, errorCode: nil, resultEntryId: "entry-1"
        )
    }

    private func runningPage(firstTranslation: String = "") -> ManagedAnalysisResultsPage {
        let batches = firstTranslation.isEmpty
            ? []
            : [ManagedAnalysisCompletedBatch(
                batchIndex: 0,
                subtitles: [cue(0, translation: firstTranslation)]
            )]
        return ManagedAnalysisResultsPage(
            jobId: "job-1", entryId: "entry-1", status: .running,
            completedCues: batches.isEmpty ? 0 : 1, totalCues: 2,
            nextBatchCursor: batches.isEmpty ? -1 : 0,
            batches: batches, errorCode: nil
        )
    }

    @MainActor
    func testDiscoversJobAndMergesOnlyNewDurableBatches() async throws {
        let firstCue = cue(0, translation: "第一句")
        let api = API(
            details: [entry(translations: ["", ""])],
            jobs: [job()],
            results: [ManagedAnalysisResultsPage(
                jobId: "job-1", entryId: "entry-1", status: .running,
                completedCues: 1, totalCues: 2, nextBatchCursor: 0,
                batches: [ManagedAnalysisCompletedBatch(batchIndex: 0, subtitles: [firstCue])],
                errorCode: nil
            )]
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)

        await viewModel.load(id: "entry-1", token: "token")
        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["", ""])
        await viewModel.discoverManagedAnalysis(token: "token")

        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["第一句", ""])
        XCTAssertEqual(viewModel.managedProgress?.completedCues, 1)
        let cursors = await api.cursors()
        XCTAssertEqual(cursors, [-1])
    }

    @MainActor
    func testCompletionReloadsFinalEntryAndDropsProgressiveOverlay() async throws {
        let partial = cue(0, translation: "临时第一句")
        let final = entry(translations: ["最终第一句", "最终第二句"])
        let api = API(
            details: [entry(translations: ["", ""]), final],
            jobs: [job()],
            results: [
                ManagedAnalysisResultsPage(
                    jobId: "job-1", entryId: "entry-1", status: .running,
                    completedCues: 1, totalCues: 2, nextBatchCursor: 0,
                    batches: [ManagedAnalysisCompletedBatch(batchIndex: 0, subtitles: [partial])],
                    errorCode: nil
                ),
                ManagedAnalysisResultsPage(
                    jobId: "job-1", entryId: "entry-1", status: .completed,
                    completedCues: 2, totalCues: 2, nextBatchCursor: 1,
                    batches: [ManagedAnalysisCompletedBatch(batchIndex: 1, subtitles: [cue(1, translation: "临时第二句")])],
                    errorCode: nil
                ),
            ]
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)

        await viewModel.load(id: "entry-1", token: "token")
        await viewModel.discoverManagedAnalysis(token: "token")
        try await viewModel.pollManagedAnalysisOnce(token: "token")

        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["最终第一句", "最终第二句"])
        XCTAssertEqual(viewModel.managedProgress?.status, .completed)
        let cursors = await api.cursors()
        XCTAssertEqual(cursors, [-1, 0])
    }

    @MainActor
    func testCompletionKeepsEditingLockedUntilFinalDetailRetrySucceeds() async throws {
        let final = entry(translations: ["最终第一句", "最终第二句"])
        let completedPage = ManagedAnalysisResultsPage(
            jobId: "job-1", entryId: "entry-1", status: .completed,
            completedCues: 2, totalCues: 2, nextBatchCursor: 1,
            batches: [ManagedAnalysisCompletedBatch(
                batchIndex: 1,
                subtitles: [cue(0, translation: "临时第一句"), cue(1, translation: "临时第二句")]
            )],
            errorCode: nil
        )
        let api = API(
            details: [entry(translations: ["", ""]), final],
            jobs: [job()],
            results: [completedPage, ManagedAnalysisResultsPage(
                jobId: "job-1", entryId: "entry-1", status: .completed,
                completedCues: 2, totalCues: 2, nextBatchCursor: 1,
                batches: [], errorCode: nil
            )],
            failingDetailCalls: [2]
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)

        await viewModel.load(id: "entry-1", token: "token")
        await viewModel.discoverManagedAnalysis(token: "token")
        XCTAssertTrue(viewModel.managedFinalSyncPending)
        XCTAssertTrue(viewModel.managedEditingBlocked)

        try await viewModel.pollManagedAnalysisOnce(token: "token")
        XCTAssertFalse(viewModel.managedFinalSyncPending)
        XCTAssertFalse(viewModel.managedEditingBlocked)
        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["最终第一句", "最终第二句"])
    }

    @MainActor
    func testCancelKeepsMergedCuesAndExposesResume() async throws {
        let api = API(
            details: [entry(translations: ["", ""])],
            jobs: [job()],
            results: [runningPage(firstTranslation: "第一句")],
            cancelResponse: job(status: .cancelled, completedCues: 1)
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
        await viewModel.load(id: "entry-1", token: "token")
        await viewModel.discoverManagedAnalysis(token: "token")
        let before = viewModel.displayedCues.map(\.translation)
        await viewModel.cancelManagedAnalysis(token: "token")

        XCTAssertEqual(viewModel.managedProgress?.status, .cancelled)
        XCTAssertEqual(viewModel.displayedCues.map(\.translation), before)
        XCTAssertTrue(viewModel.managedProgress?.canResume == true)
        let calls = await api.cancelCalls()
        XCTAssertEqual(calls, ["job-1"])
        XCTAssertNil(viewModel.managedProgressError)
    }

    @MainActor
    func testCancelFailurePreservesRunningStateAndShowsRetryableError() async throws {
        let api = API(
            details: [entry(translations: ["", ""])],
            jobs: [job()],
            results: [runningPage()],
            cancelError: .network("offline")
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
        await viewModel.load(id: "entry-1", token: "token")
        await viewModel.discoverManagedAnalysis(token: "token")
        await viewModel.cancelManagedAnalysis(token: "token")

        XCTAssertEqual(viewModel.managedProgress?.status, .running)
        XCTAssertEqual(viewModel.managedProgressError, "暂时无法停止解析，请稍后重试")
        XCTAssertFalse(viewModel.managedCancelling)
    }

    @MainActor
    func testCancelCompletionRaceReloadsFinalEntry() async throws {
        let final = entry(translations: ["最终第一句", "最终第二句"])
        let api = API(
            details: [entry(translations: ["", ""]), final],
            jobs: [job()],
            results: [runningPage()],
            cancelError: .invalidState,
            jobResponses: [job(status: .completed, completedCues: 2)]
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
        await viewModel.load(id: "entry-1", token: "token")
        await viewModel.discoverManagedAnalysis(token: "token")
        await viewModel.cancelManagedAnalysis(token: "token")

        XCTAssertEqual(viewModel.managedProgress?.status, .completed)
        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["最终第一句", "最终第二句"])
        XCTAssertNil(viewModel.managedProgressError)
    }

    @MainActor
    func testCompletedCancelResponseReloadsFinalEntry() async throws {
        let final = entry(translations: ["最终第一句", "最终第二句"])
        let api = API(
            details: [entry(translations: ["", ""]), final],
            jobs: [job()],
            results: [runningPage()],
            cancelResponse: job(status: .completed, completedCues: 2)
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
        await viewModel.load(id: "entry-1", token: "token")
        await viewModel.discoverManagedAnalysis(token: "token")
        await viewModel.cancelManagedAnalysis(token: "token")

        XCTAssertEqual(viewModel.managedProgress?.status, .completed)
        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["最终第一句", "最终第二句"])
        XCTAssertFalse(viewModel.managedFinalSyncPending)
    }

    @MainActor
    func testTerminalHydrationFailureKeepsExistingTranslationAndCanRecover() async throws {
        let partialPage = ManagedAnalysisResultsPage(
            jobId: "job-1", entryId: "entry-1", status: .cancelled,
            completedCues: 1, totalCues: 2, nextBatchCursor: 0,
            batches: [ManagedAnalysisCompletedBatch(
                batchIndex: 0,
                subtitles: [cue(0, translation: "第一句")]
            )],
            errorCode: nil
        )
        let api = API(
            details: [entry(translations: ["", ""])],
            jobs: [job(status: .cancelled, completedCues: 1)],
            results: [partialPage, partialPage],
            failingResultCalls: [2]
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
        await viewModel.load(id: "entry-1", token: "token")
        await viewModel.discoverManagedAnalysis(token: "token")
        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["第一句", ""])

        await viewModel.discoverManagedAnalysis(token: "token")

        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["第一句", ""])
        XCTAssertTrue(viewModel.managedHydrationPending)
        try await viewModel.pollManagedAnalysisOnce(token: "token")
        XCTAssertFalse(viewModel.managedHydrationPending)
        XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["第一句", ""])
    }

    @MainActor
    func testCancelUnauthorizedShowsLoginExpiredMessage() async throws {
        let api = API(
            details: [entry(translations: ["", ""])],
            jobs: [job()],
            results: [runningPage()],
            cancelError: .unauthorized
        )
        let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
        await viewModel.load(id: "entry-1", token: "token")
        await viewModel.discoverManagedAnalysis(token: "token")
        await viewModel.cancelManagedAnalysis(token: "token")

        XCTAssertEqual(viewModel.managedProgressError, "登录已过期，请到「我的」重新登录")
        XCTAssertFalse(viewModel.managedCancelling)
    }
}
