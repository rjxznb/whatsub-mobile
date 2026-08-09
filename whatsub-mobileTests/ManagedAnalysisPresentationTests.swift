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

    func testLibraryProgressLabelsStayCompactAndTerminalCompletionDisappears() {
        XCTAssertEqual(job(.queued).libraryProgressLabel, "等待 AI 解析")
        XCTAssertEqual(job(.running).libraryProgressLabel, "AI 解析中 · 25/100")
        XCTAssertEqual(job(.pausedQuota).libraryProgressLabel, "仅英文 · 解析已暂停")
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

    func testProvisionalEntryCanOpenBeforeAnalysisCompletes() {
        XCTAssertEqual(job(.queued, entryID: "entry-1").provisionalEntryID, "entry-1")
        XCTAssertEqual(job(.running, entryID: "entry-1").provisionalEntryID, "entry-1")
        XCTAssertNil(job(.running).provisionalEntryID)
        XCTAssertNil(job(.running, entryID: "  ").provisionalEntryID)
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
