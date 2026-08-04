import XCTest
@testable import whatsub_mobile

@MainActor
final class PhotoAITrialLifecycleTests: XCTestCase {
    func testSuccessfulAnalysisCallsSuccessOnceBeforeReviewIsPublished() async {
        var callbackCount = 0
        var hadAnalysisAtCallback = false
        var viewModel: PhotoReviewViewModel!
        viewModel = PhotoReviewViewModel(
            analyzer: PhotoAnalyzer { _ in
                """
                {
                  "translation": "你好，世界。",
                  "phrases": [{
                    "phrase": "hello world",
                    "meaningZh": "你好，世界",
                    "usageNote": "常见示例短语",
                    "contextSentence": "Hello world."
                  }]
                }
                """
            },
            onSuccessfulAnalysis: {
                callbackCount += 1
                hadAnalysisAtCallback = viewModel.analysis != nil
                return true
            }
        )
        viewModel.editOCRText("Hello world.")

        await viewModel.analyze()
        await viewModel.analyze()

        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(hadAnalysisAtCallback)
        XCTAssertNotNil(viewModel.analysis)
        XCTAssertEqual(viewModel.phase, .reviewing)
    }

    func testEmptyAnalysisDoesNotCallSuccess() async {
        var callbackCount = 0
        let viewModel = PhotoReviewViewModel(
            analyzer: PhotoAnalyzer { _ in
                "{\"translation\":\"\",\"phrases\":[]}"
            },
            onSuccessfulAnalysis: { callbackCount += 1; return true }
        )
        viewModel.editOCRText("Unreadable fragment")

        await viewModel.analyze()

        XCTAssertEqual(callbackCount, 0)
        if case .error = viewModel.phase {} else { XCTFail("empty analysis should fail") }
    }

    func testEmptyOCRDoesNotCallSuccess() async {
        var callbackCount = 0
        let viewModel = PhotoReviewViewModel(
            analyzer: PhotoAnalyzer { _ in XCTFail("analyzer should not run"); return "{}" },
            onSuccessfulAnalysis: { callbackCount += 1; return true }
        )

        await viewModel.analyze()

        XCTAssertEqual(callbackCount, 0)
        if case .error = viewModel.phase {} else { XCTFail("empty OCR should fail") }
    }

    func testCancelledFlowDoesNotPublishOrConsumeLateAnalysis() async {
        actor AnalysisGate {
            var continuation: CheckedContinuation<String, Never>?
            func wait() async -> String { await withCheckedContinuation { continuation = $0 } }
            func isWaiting() -> Bool { continuation != nil }
            func finish() {
                continuation?.resume(returning: "{\"translation\":\"late\",\"phrases\":[]}")
                continuation = nil
            }
        }
        let gate = AnalysisGate()
        var callbackCount = 0
        let viewModel = PhotoReviewViewModel(
            analyzer: PhotoAnalyzer { _ in await gate.wait() },
            onSuccessfulAnalysis: { callbackCount += 1; return true }
        )
        viewModel.editOCRText("Hello")
        let task = Task { await viewModel.analyze() }
        while !(await gate.isWaiting()) { await Task.yield() }

        viewModel.cancelFlow()
        await gate.finish()
        await task.value

        XCTAssertEqual(callbackCount, 0)
        XCTAssertNil(viewModel.analysis)
    }

    func testDurableConsumeFailurePreventsAnalysisDisplay() async {
        let viewModel = PhotoReviewViewModel(
            analyzer: PhotoAnalyzer { _ in "{\"translation\":\"value\",\"phrases\":[]}" },
            onSuccessfulAnalysis: { false }
        )
        viewModel.editOCRText("Hello")

        await viewModel.analyze()

        XCTAssertNil(viewModel.analysis)
        if case .error = viewModel.phase {} else { XCTFail("durability failure should fail closed") }
    }
}
