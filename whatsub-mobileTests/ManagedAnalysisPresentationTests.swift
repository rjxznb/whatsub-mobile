import XCTest
@testable import whatsub_mobile

@MainActor
final class ManagedAnalysisPresentationTests: XCTestCase {
    private func job(
        _ status: ManagedAnalysisJobStatus,
        completed: Int = 25,
        total: Int = 100,
        error: ManagedAnalysisFailureCode? = nil,
        entryID: String? = nil
    ) -> ManagedAnalysisJob {
        ManagedAnalysisJob(
            jobId: "job", status: status, tier: .free,
            createdAt: 1, updatedAt: 2,
            completedCues: completed, totalCues: total,
            tokensIn: 0, tokensOut: 0,
            errorCode: error, resultEntryId: entryID
        )
    }

    func testAllManagedJobStatusesHaveActionablePresentation() {
        XCTAssertEqual(job(.queued).presentation.label, "排队中")
        XCTAssertEqual(job(.running).presentation.label, "解析中 25/100")
        XCTAssertEqual(job(.pausedQuota).presentation.label, "额度不足，已暂停")
        XCTAssertEqual(job(.failed, error: .upstreamUnavailable).presentation.label, "解析失败")
        XCTAssertEqual(job(.completed, entryID: "entry-1").presentation.label, "已完成")
        XCTAssertEqual(job(.cancelled).presentation.label, "已取消")
        XCTAssertTrue(job(.queued).presentation.canCancel)
        XCTAssertTrue(job(.pausedQuota).presentation.canResume)
        XCTAssertTrue(job(.failed).presentation.canResume)
        XCTAssertTrue(job(.cancelled).presentation.canResume)
        XCTAssertEqual(job(.completed, entryID: "entry-1").presentation.entryID, "entry-1")
    }

    func testMalformedModelOutputHasActionableRecoveryCopy() {
        XCTAssertEqual(job(.failed, error: .invalidAnalysisCue).presentation.detail, "AI 返回格式异常")
        XCTAssertEqual(job(.failed, error: .invalidSSE).presentation.detail, "AI 返回格式异常")
        XCTAssertTrue(job(.failed, error: .invalidAnalysisCue).presentation.canResume)
        XCTAssertEqual(
            ManagedAnalysisProgressState(job: job(.failed, error: .invalidAnalysisCue)).failureDetail,
            "AI 返回格式异常"
        )
    }

    func testLearningGuideAvailabilityTracksManagedAnalysisLifecycle() {
        XCTAssertEqual(VideoLearningGuideAnalysisAvailability.make(status: nil), .available)
        XCTAssertEqual(VideoLearningGuideAnalysisAvailability.make(status: .queued), .waiting)
        XCTAssertEqual(VideoLearningGuideAnalysisAvailability.make(status: .running), .waiting)
        XCTAssertEqual(VideoLearningGuideAnalysisAvailability.make(status: .completed), .available)
        XCTAssertEqual(VideoLearningGuideAnalysisAvailability.make(status: .failed), .resumeRequired)
        XCTAssertEqual(VideoLearningGuideAnalysisAvailability.make(status: .cancelled), .resumeRequired)
        XCTAssertEqual(VideoLearningGuideAnalysisAvailability.make(status: .pausedQuota), .resumeRequired)
    }

    func testLibraryProgressLabelsStayCompactAndTerminalCompletionDisappears() {
        XCTAssertEqual(job(.queued).libraryProgressLabel, "等待 AI 解析")
        XCTAssertEqual(job(.running).libraryProgressLabel, "AI 解析中 · 25/100")
        XCTAssertEqual(job(.pausedQuota).libraryProgressLabel, "部分解析 · 解析已暂停")
        XCTAssertNil(job(.completed).libraryProgressLabel)
    }

    func testLibraryProgressCancellationCapabilityAndLabels() {
        XCTAssertTrue(ManagedAnalysisProgressState(job: job(.queued)).canCancel)
        XCTAssertTrue(ManagedAnalysisProgressState(job: job(.running)).canCancel)
        XCTAssertFalse(ManagedAnalysisProgressState(job: job(.failed)).canCancel)
        XCTAssertEqual(
            ManagedAnalysisProgressState(job: job(.cancelled, completed: 25)).label,
            "部分解析 · 已停止"
        )
        XCTAssertEqual(
            ManagedAnalysisProgressState(job: job(.cancelled, completed: 0)).label,
            "仅英文 · 已停止"
        )
    }

    func testLibraryCardLabelsAcknowledgePartialProgress() {
        XCTAssertEqual(job(.pausedQuota, completed: 25).libraryProgressLabel, "部分解析 · 解析已暂停")
        XCTAssertEqual(job(.failed, completed: 25).libraryProgressLabel, "部分解析 · AI 解析失败")
        XCTAssertEqual(job(.cancelled, completed: 25).libraryProgressLabel, "部分解析 · 已停止")
        XCTAssertEqual(job(.cancelled, completed: 0).libraryProgressLabel, "仅英文 · 已停止")
    }

    func testLibraryDetailPollingStartPolicyRequiresVisibleActiveTask() {
        XCTAssertTrue(LibraryDetailPollingStartPolicy.shouldStart(
            taskIsCancelled: false,
            sceneIsActive: true,
            viewIsVisible: true
        ))
        XCTAssertFalse(LibraryDetailPollingStartPolicy.shouldStart(
            taskIsCancelled: true,
            sceneIsActive: true,
            viewIsVisible: true
        ))
        XCTAssertFalse(LibraryDetailPollingStartPolicy.shouldStart(
            taskIsCancelled: false,
            sceneIsActive: false,
            viewIsVisible: true
        ))
        XCTAssertFalse(LibraryDetailPollingStartPolicy.shouldStart(
            taskIsCancelled: false,
            sceneIsActive: true,
            viewIsVisible: false
        ))
    }

    func testPollingLifecycleReevaluatesCurrentSceneAndVisibility() {
        let lifecycle = LibraryDetailPollingLifecycle()
        lifecycle.appear(sceneIsActive: true)
        XCTAssertTrue(lifecycle.shouldStart(taskIsCancelled: false))

        lifecycle.sceneChanged(isActive: false)
        XCTAssertFalse(lifecycle.shouldStart(taskIsCancelled: false))

        lifecycle.sceneChanged(isActive: true)
        XCTAssertTrue(lifecycle.shouldStart(taskIsCancelled: false))

        lifecycle.disappear()
        XCTAssertFalse(lifecycle.shouldStart(taskIsCancelled: false))
    }

    func testProvisionalEntryCanOpenBeforeAnalysisCompletes() {
        XCTAssertEqual(job(.queued, entryID: "entry-1").provisionalEntryID, "entry-1")
        XCTAssertEqual(job(.running, entryID: "entry-1").provisionalEntryID, "entry-1")
        XCTAssertNil(job(.running).provisionalEntryID)
        XCTAssertNil(job(.running, entryID: "  ").provisionalEntryID)
    }

    func testQueuePresentationIsCompactAndConservative() {
        XCTAssertNil(ManagedAnalysisQueuePresentation.make(
            status: .queued,
            jobsAhead: nil,
            estimatedStartSeconds: nil,
            connection: .streaming
        ).detail)

        XCTAssertEqual(ManagedAnalysisQueuePresentation.make(
            status: .queued,
            jobsAhead: 0,
            estimatedStartSeconds: 0,
            connection: .streaming
        ).detail, "即将开始解析")

        XCTAssertEqual(ManagedAnalysisQueuePresentation.make(
            status: .queued,
            jobsAhead: 1,
            estimatedStartSeconds: 1,
            connection: .streaming
        ).detail, "前面还有 1 个任务，预计约 1 分钟开始")

        XCTAssertEqual(ManagedAnalysisQueuePresentation.make(
            status: .queued,
            jobsAhead: 3,
            estimatedStartSeconds: 121,
            connection: .streaming
        ).detail, "前面还有 3 个任务，预计约 3 分钟开始")
    }

    func testQueuePresentationHidesEstimateAfterProcessingStarts() {
        let presentation = ManagedAnalysisQueuePresentation.make(
            status: .running,
            jobsAhead: 9,
            estimatedStartSeconds: 600,
            connection: .streaming
        )

        XCTAssertNil(presentation.detail)
        XCTAssertEqual(presentation.accessibilityLabel, "服务器解析中")
    }

    func testQueuePresentationDistinguishesReconnectAndPollingFallback() {
        let reconnecting = ManagedAnalysisQueuePresentation.make(
            status: .running,
            jobsAhead: nil,
            estimatedStartSeconds: nil,
            connection: .reconnecting
        )
        XCTAssertEqual(reconnecting.detail, "正在重新连接进度…")
        XCTAssertEqual(reconnecting.accessibilityLabel, "重新连接中")

        let polling = ManagedAnalysisQueuePresentation.make(
            status: .running,
            jobsAhead: nil,
            estimatedStartSeconds: nil,
            connection: .pollingFallback
        )
        XCTAssertEqual(polling.detail, "实时连接暂不可用，正在轮询恢复")
        XCTAssertEqual(polling.accessibilityLabel, "轮询恢复中")
    }

    func testOldLiveActivityPayloadDecodesWithoutRecentEntryID() throws {
        let old = Data(#"{"inProgress":0,"completed":1,"failed":0,"recentTitle":"Done"}"#.utf8)
        let state = try JSONDecoder().decode(ImportActivityAttributes.ContentState.self, from: old)
        XCTAssertNil(state.recentEntryId)
        XCTAssertEqual(state.tapURL.absoluteString, "whatsub://library")
    }

    func testCompletedLiveActivityDeepLinksToExactLibraryEntry() {
        let state = ImportActivityAttributes.ContentState(
            inProgress: 0, completed: 1, failed: 0,
            recentTitle: "Done", recentEntryId: "entry / 中文"
        )
        let components = URLComponents(url: state.tapURL, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.host, "library")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "id" })?.value, "entry / 中文")
    }

    func testFailedLiveActivityRoutesToQueueForRecovery() {
        let state = ImportActivityAttributes.ContentState(
            inProgress: 0, completed: 0, failed: 1,
            recentTitle: "Failed", recentEntryId: nil
        )
        XCTAssertEqual(state.tapURL.absoluteString, "whatsub://import-queue")
    }

    func testAppStateRoutesCompletedDeepLinkIntoLibrary() {
        let state = AppState()
        state.selectedTab = 3

        state.routeAppURL(URL(string: "whatsub://library?id=entry-123")!)

        XCTAssertEqual(state.selectedTab, 0)
        XCTAssertEqual(state.pendingLibraryEntryID, "entry-123")
    }

    func testImportQueueDeepLinkStillRoutesToMeQueue() {
        let state = AppState()
        state.routeAppURL(URL(string: "whatsub://import-queue")!)
        XCTAssertEqual(state.selectedTab, 3)
        XCTAssertTrue(state.meShowImportQueue)
    }
}
