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
            onSuccessfulAnalysis: { callbackCount += 1 }
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
            onSuccessfulAnalysis: { callbackCount += 1 }
        )

        await viewModel.analyze()

        XCTAssertEqual(callbackCount, 0)
        if case .error = viewModel.phase {} else { XCTFail("empty OCR should fail") }
    }
}
