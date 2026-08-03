import XCTest
@testable import whatsub_mobile

@MainActor
final class LiveSceneTrialLifecycleTests: XCTestCase {
    private let scene = SceneContext(
        labels: [SceneLabel(identifier: "street", confidence: 0.9)],
        humanCount: 1,
        animalCount: 0
    )

    private let prompt = SpeakingPrompt(
        promptEn: "Describe the street.",
        sampleAnswer: "A person is walking down a busy street.",
        sampleAnswerZh: "一个人正走在繁忙的街道上。",
        targetVocab: ["walk down"],
        difficulty: 1
    )

    func testSuccessfulGradeCallsSuccessOnceBeforeReviewIsPublished() async {
        var callbackCount = 0
        var wasReviewAtCallback = false
        var viewModel: LiveSceneViewModel!
        viewModel = LiveSceneViewModel(
            grader: LiveSceneGrader { _ in
                """
                {
                  "score": 4,
                  "feedback": "表达清楚。",
                  "vocabHits": []
                }
                """
            },
            onSuccessfulGrade: {
                callbackCount += 1
                if case .review = viewModel.phase { wasReviewAtCallback = true }
            }
        )

        await viewModel.runGrader(scene: scene, prompt: prompt, transcript: "I see a street.")
        await viewModel.runGrader(scene: scene, prompt: prompt, transcript: "I see it again.")

        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(wasReviewAtCallback)
        if case .review = viewModel.phase {} else { XCTFail("valid grade should be published") }
    }

    func testMalformedOrFailedGradeDoesNotCallSuccess() async {
        var callbackCount = 0
        let viewModel = LiveSceneViewModel(
            grader: LiveSceneGrader { _ in "{}" },
            onSuccessfulGrade: { callbackCount += 1 }
        )

        await viewModel.runGrader(scene: scene, prompt: prompt, transcript: "I see a street.")

        XCTAssertEqual(callbackCount, 0)
        if case .error = viewModel.phase {} else { XCTFail("empty grade should fail") }
    }
}
