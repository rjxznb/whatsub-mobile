import XCTest
@testable import whatsub_mobile

final class LibraryManagedAnalysisTests: XCTestCase {
    private actor API: LibraryDesktopReplacementAPI, ManagedAnalysisClientProtocol {
        private var detailQueue: [LibraryEntryDetail]
        private var resultQueue: [ManagedAnalysisResultsPage]
        private(set) var requestedCursors: [Int] = []
        var listedJobs: [ManagedAnalysisJob]

        init(
            details: [LibraryEntryDetail],
            jobs: [ManagedAnalysisJob],
            results: [ManagedAnalysisResultsPage]
        ) {
            detailQueue = details
            listedJobs = jobs
            resultQueue = results
        }

        func cursors() -> [Int] { requestedCursors }

        func libraryEntry(id: String, token: String) async throws -> LibraryEntryDetail {
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

        func job(id: String, token: String) async throws -> ManagedAnalysisJob { listedJobs[0] }
        func jobs(token: String) async throws -> [ManagedAnalysisJob] { listedJobs }

        func results(
            id: String,
            afterBatch: Int,
            token: String
        ) async throws -> ManagedAnalysisResultsPage {
            requestedCursors.append(afterBatch)
            guard !resultQueue.isEmpty else { throw ManagedAnalysisClientError.notFound }
            return resultQueue.removeFirst()
        }

        func cancel(id: String, token: String) async throws -> ManagedAnalysisJob { listedJobs[0] }

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

    private func job(status: ManagedAnalysisJobStatus = .running) -> ManagedAnalysisJob {
        ManagedAnalysisJob(
            jobId: "job-1", status: status, tier: .pro,
            createdAt: 1, updatedAt: 2, completedCues: 0, totalCues: 2,
            tokensIn: 0, tokensOut: 0, errorCode: nil, resultEntryId: "entry-1"
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
        XCTAssertEqual(await api.cursors(), [-1])
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
        XCTAssertEqual(await api.cursors(), [-1, 0])
    }
}
