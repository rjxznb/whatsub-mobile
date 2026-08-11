import XCTest
@testable import whatsub_mobile

private actor LearningGuideDetailAPISpy: LibraryDesktopReplacementAPI {
    private var details: [LibraryEntryDetail]
    private(set) var detailCallCount = 0

    init(_ details: [LibraryEntryDetail]) {
        self.details = details
    }

    func libraryEntry(id: String, token: String) async throws -> LibraryEntryDetail {
        detailCallCount += 1
        if details.count == 1 { return details[0] }
        return details.removeFirst()
    }

    func listImportQueue(
        token: String
    ) async throws -> (items: [ImportQueueItem], desktopSeenSecondsAgo: Int?) {
        ([], nil)
    }

    func enqueueReplacement(
        url: String,
        targetLibraryEntryId: String,
        token: String
    ) async throws -> EnqueueImportResponse {
        EnqueueImportResponse(id: "queue", desktopSeenSecondsAgo: nil, status: "pending")
    }
}

private actor GatedSummaryProviderSpy {
    private let summary: AnalysisSummary
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(summary: AnalysisSummary = makeAnalysisSummary()) {
        self.summary = summary
    }

    func call(
        entry: LibraryEntryDetail,
        settings: LlmSettings,
        token: String
    ) async throws -> AnalysisSummary {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        return summary
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Deliberately ignores task cancellation so VM revision checks, rather than
/// cooperative dependency behavior, must protect refreshed detail state.
private actor CancellationIgnoringGatedSummaryProviderSpy {
    private let summary: AnalysisSummary
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(summary: AnalysisSummary = makeAnalysisSummary()) {
        self.summary = summary
    }

    func call(
        entry: LibraryEntryDetail,
        settings: LlmSettings,
        token: String
    ) async throws -> AnalysisSummary {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        return summary
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedGuideReloadDetailAPISpy: LibraryDesktopReplacementAPI {
    private let initial: LibraryEntryDetail
    private let staleGuideReload: LibraryEntryDetail
    private let refreshedByUser: LibraryEntryDetail
    private var reloadContinuation: CheckedContinuation<Void, Never>?
    private(set) var detailCallCount = 0

    init(
        initial: LibraryEntryDetail,
        staleGuideReload: LibraryEntryDetail,
        refreshedByUser: LibraryEntryDetail
    ) {
        self.initial = initial
        self.staleGuideReload = staleGuideReload
        self.refreshedByUser = refreshedByUser
    }

    func libraryEntry(id: String, token: String) async throws -> LibraryEntryDetail {
        detailCallCount += 1
        switch detailCallCount {
        case 1:
            return initial
        case 2:
            await withCheckedContinuation { reloadContinuation = $0 }
            return staleGuideReload
        default:
            return refreshedByUser
        }
    }

    func listImportQueue(
        token: String
    ) async throws -> (items: [ImportQueueItem], desktopSeenSecondsAgo: Int?) {
        ([], nil)
    }

    func enqueueReplacement(
        url: String,
        targetLibraryEntryId: String,
        token: String
    ) async throws -> EnqueueImportResponse {
        EnqueueImportResponse(id: "queue", desktopSeenSecondsAgo: nil, status: "pending")
    }

    func releaseGuideReload() {
        reloadContinuation?.resume()
        reloadContinuation = nil
    }
}

@MainActor
final class VideoLearningGuidePresentationTests: XCTestCase {
    func testCardPresentationContainsNoScoreAndUsesApprovedSectionOrder() {
        let presentation = VideoLearningGuidePresentation(guide: makeLearningGuide())

        XCTAssertEqual(presentation.verdictText, "建议挑选重点片段")
        XCTAssertEqual(presentation.cefrText, "B2")
        XCTAssertEqual(
            presentation.sections.map(\.title),
            ["30 秒概览", "内容提要", "为什么值得学", "适合谁学", "文化与语境", "学习建议", "重点片段"]
        )
        XCTAssertFalse(presentation.allVisibleText.contains("/10"))
        XCTAssertFalse(presentation.allVisibleText.contains("评分"))
        XCTAssertFalse(presentation.allVisibleText.contains("得分"))
    }

    func testApplyingLearningGuideIsPureAndPreservesDisplayedEntryUntilUsed() {
        let original = makeLearningGuideEntry(fingerprint: "f1")

        let updated = original.applyingLearningGuide(makeGuideResponse(fingerprint: "f1"))

        XCTAssertNil(original.analysisJson.learningGuide)
        XCTAssertEqual(updated.analysisJson.learningGuide, makeLearningGuide())
        XCTAssertEqual(updated.analysisJson.contextProfile, makeVideoContextProfile())
        XCTAssertEqual(updated.analysisJson.learningGuideSourceFingerprint, "f1")
        XCTAssertEqual(updated.analysisFingerprint, "f1")
        XCTAssertEqual(updated.analysisJson.subtitles.map(\.text), ["I see your point."])
    }

    func testGenerateGuideIsSingleFlightAndDoesNotMutateEntryBeforePatchSucceeds() async {
        let entry = makeLearningGuideEntry(fingerprint: "f1")
        let detailAPI = LearningGuideDetailAPISpy([entry])
        let patchAPI = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "f1"))])
        let llm = GatedSummaryProviderSpy()
        let service = VideoLearningGuideService(api: patchAPI, summaryProvider: llm.call)
        let vm = LibraryDetailViewModel(api: detailAPI, guideService: service)
        await vm.load(id: entry.id, token: "token")

        let first = Task { await vm.generateGuide(settings: LlmSettings(), token: "token") }
        while await llm.callCount == 0 { await Task.yield() }
        let second = Task { await vm.generateGuide(settings: LlmSettings(), token: "token") }
        await Task.yield()

        let inFlightCallCount = await llm.callCount
        XCTAssertEqual(inFlightCallCount, 1)
        XCTAssertNil(vm.entry?.analysisJson.learningGuide)
        XCTAssertEqual(vm.guidePhase, .loading)

        await llm.release()
        await first.value
        await second.value

        let fingerprints = await patchAPI.expectedFingerprints
        XCTAssertEqual(fingerprints, ["f1"])
        XCTAssertEqual(vm.entry?.analysisJson.learningGuide, makeLearningGuide())
        XCTAssertEqual(vm.guidePhase, .ready)
    }

    func testCancellationLeavesMissingGuideAndNeverPatches() async {
        let entry = makeLearningGuideEntry(fingerprint: "f1")
        let detailAPI = LearningGuideDetailAPISpy([entry])
        let patchAPI = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "f1"))])
        let llm = CancellableSummaryProviderSpy()
        let service = VideoLearningGuideService(api: patchAPI, summaryProvider: llm.call)
        let vm = LibraryDetailViewModel(api: detailAPI, guideService: service)
        await vm.load(id: entry.id, token: "token")
        let task = Task { await vm.generateGuide(settings: LlmSettings(), token: "token") }
        while await llm.callCount == 0 { await Task.yield() }

        vm.cancelGuideGeneration()
        await task.value

        XCTAssertNil(vm.entry?.analysisJson.learningGuide)
        XCTAssertEqual(vm.guidePhase, .idle)
        let fingerprints = await patchAPI.expectedFingerprints
        XCTAssertEqual(fingerprints, [])
    }

    func testLoadSupersedesInFlightGuideGenerationAndPreservesRefreshedPhase() async {
        let before = makeLearningGuideEntry(fingerprint: "f1", title: "Before refresh")
        let refreshed = makeLearningGuideEntry(fingerprint: "f2", title: "After refresh")
        let detailAPI = LearningGuideDetailAPISpy([before, refreshed])
        let patchAPI = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "f1"))])
        let llm = CancellationIgnoringGatedSummaryProviderSpy()
        let service = VideoLearningGuideService(api: patchAPI, summaryProvider: llm.call)
        let vm = LibraryDetailViewModel(api: detailAPI, guideService: service)
        await vm.load(id: before.id, token: "token")

        let oldGeneration = Task {
            await vm.generateGuide(settings: LlmSettings(), token: "token")
        }
        while await llm.callCount == 0 { await Task.yield() }

        await vm.load(id: refreshed.id, token: "token")
        await llm.release()
        await oldGeneration.value

        XCTAssertEqual(vm.entry?.title, "After refresh")
        XCTAssertEqual(vm.entry?.analysisFingerprint, "f2")
        XCTAssertNil(vm.entry?.analysisJson.learningGuide)
        XCTAssertEqual(vm.guidePhase, .idle)
        let fingerprints = await patchAPI.expectedFingerprints
        XCTAssertEqual(fingerprints, [])
    }

    func testSupersededGuideTaskCannotClearNewTaskOrOverrideItsLoadingPhase() async {
        let before = makeLearningGuideEntry(fingerprint: "f1", title: "Before refresh")
        let refreshed = makeLearningGuideEntry(fingerprint: "f2", title: "After refresh")
        let detailAPI = LearningGuideDetailAPISpy([before, refreshed])
        let patchAPI = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "f2"))])
        let oldLLM = CancellationIgnoringGatedSummaryProviderSpy()
        let newLLM = CancellationIgnoringGatedSummaryProviderSpy()
        let service = VideoLearningGuideService(
            api: patchAPI,
            summaryProvider: { entry, settings, token in
                if entry.analysisFingerprint == "f1" {
                    return try await oldLLM.call(entry: entry, settings: settings, token: token)
                }
                return try await newLLM.call(entry: entry, settings: settings, token: token)
            }
        )
        let vm = LibraryDetailViewModel(api: detailAPI, guideService: service)
        await vm.load(id: before.id, token: "token")

        let oldGeneration = Task {
            await vm.generateGuide(settings: LlmSettings(), token: "token")
        }
        while await oldLLM.callCount == 0 { await Task.yield() }
        await vm.load(id: refreshed.id, token: "token")

        let newGeneration = Task {
            await vm.generateGuide(settings: LlmSettings(), token: "token")
        }
        for _ in 0..<1_000 {
            if await newLLM.callCount > 0 { break }
            await Task.yield()
        }
        let newCallStarted = await newLLM.callCount == 1
        XCTAssertTrue(newCallStarted)

        await oldLLM.release()
        await oldGeneration.value

        XCTAssertEqual(vm.entry?.title, "After refresh")
        XCTAssertNil(vm.entry?.analysisJson.learningGuide)
        XCTAssertEqual(vm.guidePhase, .loading)

        await newLLM.release()
        await newGeneration.value
        XCTAssertEqual(vm.entry?.title, "After refresh")
        XCTAssertEqual(vm.entry?.analysisJson.learningGuide, makeLearningGuide())
        XCTAssertEqual(vm.guidePhase, .ready)
        let fingerprints = await patchAPI.expectedFingerprints
        XCTAssertEqual(fingerprints, ["f2"])
    }

    func testStaleGuideReloadCannotPublishAfterNewerUserLoad() async {
        let initial = makeLearningGuideEntry(fingerprint: "", title: "Initial")
        let staleReload = makeLearningGuideEntry(fingerprint: "f1", title: "Stale guide reload")
        let refreshed = makeLearningGuideEntry(fingerprint: "f2", title: "User refresh")
        let detailAPI = GatedGuideReloadDetailAPISpy(
            initial: initial,
            staleGuideReload: staleReload,
            refreshedByUser: refreshed
        )
        let patchAPI = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "f1"))])
        let llm = SummaryProviderSpy([.summary(makeAnalysisSummary())])
        let service = VideoLearningGuideService(api: patchAPI, summaryProvider: llm.call)
        let vm = LibraryDetailViewModel(api: detailAPI, guideService: service)
        await vm.load(id: initial.id, token: "token")

        let oldGeneration = Task {
            await vm.generateGuide(settings: LlmSettings(), token: "token")
        }
        while await detailAPI.detailCallCount < 2 { await Task.yield() }

        await vm.load(id: refreshed.id, token: "token")
        await detailAPI.releaseGuideReload()
        await oldGeneration.value

        XCTAssertEqual(vm.entry?.title, "User refresh")
        XCTAssertEqual(vm.entry?.analysisFingerprint, "f2")
        XCTAssertNil(vm.entry?.analysisJson.learningGuide)
        XCTAssertEqual(vm.guidePhase, .idle)
        let llmCalls = await llm.callCount
        let fingerprints = await patchAPI.expectedFingerprints
        XCTAssertEqual(llmCalls, 0)
        XCTAssertEqual(fingerprints, [])
    }

    func testRelay403UsesInlineSubscribeGuidanceAndCanRetry() async {
        let entry = makeLearningGuideEntry(fingerprint: "f1")
        let detailAPI = LearningGuideDetailAPISpy([entry])
        let patchAPI = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "f1"))])
        let llm = SummaryProviderSpy([
            .failure(.policy(code: .freeUsedUp, message: "免费额度已用完", httpStatus: 403)),
            .summary(makeAnalysisSummary()),
        ])
        let service = VideoLearningGuideService(api: patchAPI, summaryProvider: llm.call)
        let vm = LibraryDetailViewModel(api: detailAPI, guideService: service)
        await vm.load(id: entry.id, token: "token")

        await vm.generateGuide(settings: LlmSettings(), token: "token")

        XCTAssertEqual(
            vm.guidePhase,
            .failed(RemoteFailure(message: "免费额度已用完", kind: .subscribeUpsell))
        )
        XCTAssertTrue(vm.guidePhase.showsInlineRetry)

        await vm.generateGuide(settings: LlmSettings(), token: "token")
        XCTAssertEqual(vm.guidePhase, .ready)
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testConflictReloadsDetailBeforeExposingRetryAndUsesNewFingerprint() async {
        let before = makeLearningGuideEntry(fingerprint: "f1")
        let refreshed = makeLearningGuideEntry(fingerprint: "f2")
        let detailAPI = LearningGuideDetailAPISpy([before, refreshed])
        let patchAPI = LearningGuideAPISpy([
            .failure(.server(409, "analysis_changed")),
            .accepted(makeGuideResponse(fingerprint: "f2")),
        ])
        let llm = SummaryProviderSpy([
            .summary(makeAnalysisSummary()),
            .summary(makeAnalysisSummary()),
        ])
        let service = VideoLearningGuideService(api: patchAPI, summaryProvider: llm.call)
        let vm = LibraryDetailViewModel(api: detailAPI, guideService: service)
        await vm.load(id: before.id, token: "token")

        await vm.generateGuide(settings: LlmSettings(), token: "token")

        let detailCallsAfterConflict = await detailAPI.detailCallCount
        XCTAssertEqual(detailCallsAfterConflict, 2)
        XCTAssertEqual(vm.entry?.analysisFingerprint, "f2")
        XCTAssertEqual(vm.guidePhase, .analysisChanged)
        XCTAssertTrue(vm.guidePhase.showsInlineRetry)

        await vm.generateGuide(settings: LlmSettings(), token: "token")
        let fingerprints = await patchAPI.expectedFingerprints
        XCTAssertEqual(fingerprints, ["f1", "f2"])
        XCTAssertEqual(vm.guidePhase, .ready)
    }

    func testEmptyFingerprintRefreshesBeforeLLMAndShowsInlineRetryWhenStillMissing() async {
        let missing = makeLearningGuideEntry(fingerprint: "")
        let detailAPI = LearningGuideDetailAPISpy([missing, missing])
        let patchAPI = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "unused"))])
        let llm = SummaryProviderSpy([.summary(makeAnalysisSummary())])
        let service = VideoLearningGuideService(api: patchAPI, summaryProvider: llm.call)
        let vm = LibraryDetailViewModel(api: detailAPI, guideService: service)
        await vm.load(id: missing.id, token: "token")

        await vm.generateGuide(settings: LlmSettings(), token: "token")

        let detailCalls = await detailAPI.detailCallCount
        let callCount = await llm.callCount
        let fingerprints = await patchAPI.expectedFingerprints
        XCTAssertEqual(detailCalls, 2)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(fingerprints, [])
        XCTAssertEqual(vm.guidePhase, .fingerprintUnavailable)
        XCTAssertTrue(vm.guidePhase.showsInlineRetry)
    }

    func testSegmentSelectionSwitchesToSubtitlesCollapsesAndSeeks() async {
        let entry = makeLearningGuideEntry(fingerprint: "f1", guide: makeLearningGuide())
        let detailAPI = LearningGuideDetailAPISpy([entry])
        let vm = LibraryDetailViewModel(api: detailAPI)
        await vm.load(id: entry.id, token: "token")
        vm.contentTab = .collections
        vm.guideExpanded = true

        vm.selectRecommendedSegment(makeLearningGuide().topSegments[0])

        XCTAssertEqual(vm.contentTab, .subtitles)
        XCTAssertFalse(vm.guideExpanded)
        XCTAssertEqual(vm.seek?.seconds, 10)
    }
}
