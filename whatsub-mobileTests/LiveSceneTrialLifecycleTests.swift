import XCTest
import SwiftUI
import UIKit
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
                return true
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
            onSuccessfulGrade: { callbackCount += 1; return true }
        )

        await viewModel.runGrader(scene: scene, prompt: prompt, transcript: "I see a street.")

        XCTAssertEqual(callbackCount, 0)
        if case .error = viewModel.phase {} else { XCTFail("empty grade should fail") }
    }

    func testRestartedFlowIgnoresLateGrade() async {
        actor GradeGate {
            var continuation: CheckedContinuation<String, Never>?
            func wait() async -> String { await withCheckedContinuation { continuation = $0 } }
            func isWaiting() -> Bool { continuation != nil }
            func finish() {
                continuation?.resume(returning: "{\"score\":4,\"feedback\":\"late\",\"vocabHits\":[]}")
                continuation = nil
            }
        }
        let gate = GradeGate()
        var callbackCount = 0
        let viewModel = LiveSceneViewModel(
            grader: LiveSceneGrader { _ in await gate.wait() },
            onSuccessfulGrade: { callbackCount += 1; return true }
        )
        let task = Task {
            await viewModel.runGrader(scene: scene, prompt: prompt, transcript: "A street")
        }
        while !(await gate.isWaiting()) { await Task.yield() }

        viewModel.restart()
        await gate.finish()
        await task.value

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(viewModel.phase, .picker)
    }

    func testLeavingCameraTabIgnoresLateGradeAndReturningCanGradeAgain() async {
        actor GradeGate {
            var continuation: CheckedContinuation<String, Never>?
            var callCount = 0
            func next() async -> String {
                callCount += 1
                if callCount == 1 {
                    return await withCheckedContinuation { continuation = $0 }
                }
                return "{\"score\":5,\"feedback\":\"fresh\",\"vocabHits\":[]}"
            }
            func isWaiting() -> Bool { continuation != nil }
            func finish() {
                continuation?.resume(returning: "{\"score\":4,\"feedback\":\"late\",\"vocabHits\":[]}")
                continuation = nil
            }
        }
        let gate = GradeGate()
        var callbackCount = 0
        let viewModel = LiveSceneViewModel(
            grader: LiveSceneGrader { _ in await gate.next() },
            onSuccessfulGrade: { callbackCount += 1; return true }
        )
        let appState = AppState()
        appState.selectedTab = 2
        let host = UIHostingController(rootView:
            LiveSceneView(viewModel: viewModel)
                .environmentObject(StoreManager())
                .environmentObject(appState)
                .environmentObject(FeatureAccessStore())
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.loadViewIfNeeded()
        await Task.yield()

        let task = Task {
            await viewModel.runGrader(scene: scene, prompt: prompt, transcript: "A street")
        }
        while !(await gate.isWaiting()) { await Task.yield() }

        appState.selectedTab = 1
        for _ in 0..<100 {
            if case .ready = viewModel.phase { break }
            await Task.yield()
        }
        if case .ready = viewModel.phase {} else { XCTFail("tab exit should restore ready phase") }
        await gate.finish()
        await task.value

        XCTAssertEqual(callbackCount, 0)
        if case .review = viewModel.phase { XCTFail("late grade must not be published") }

        appState.selectedTab = 2
        await Task.yield()
        XCTAssertTrue(viewModel.beginReadyAttempt())
        await viewModel.runGrader(scene: scene, prompt: prompt, transcript: "A fresh street")

        XCTAssertEqual(callbackCount, 1)
        if case .review = viewModel.phase {} else { XCTFail("new grade should publish after return") }
    }
}
