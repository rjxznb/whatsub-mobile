import XCTest
@testable import whatsub_mobile

@MainActor
final class QuickChatViewModelTests: XCTestCase {
    private func progressStore() -> ProductionProgressStore {
        ProductionProgressStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("quickchat_vm_\(UUID().uuidString).json")
        )
    }

    func testFirstValidAssistantReplyCallsSuccessOnceBeforeDisplay() async {
        var callbackCount = 0
        var textAtCallback: String?
        var viewModel: QuickChatViewModel!
        viewModel = QuickChatViewModel(
            phrases: [],
            suggestedTag: nil,
            progressStore: progressStore(),
            engineDriver: .stub(turns: [
                .init(dialog: "Hello!", verdict: nil),
                .init(dialog: "Again!", verdict: nil),
            ]),
            onFirstValidAssistantReply: {
                callbackCount += 1
                textAtCallback = viewModel.turns.first?.assistantText
                return true
            }
        )

        await viewModel.start()
        await viewModel.submitUserInput("Hi")

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(textAtCallback, "")
        XCTAssertEqual(viewModel.turns.last?.assistantText, "Again!")
    }

    func testEmptyReplyDoesNotCallSuccess() async {
        var callbackCount = 0
        let viewModel = QuickChatViewModel(
            phrases: [],
            suggestedTag: nil,
            progressStore: progressStore(),
            engineDriver: .stub(turns: [.init(dialog: "   \n", verdict: nil)]),
            onFirstValidAssistantReply: { callbackCount += 1; return true }
        )

        await viewModel.start()

        XCTAssertEqual(callbackCount, 0)
        if case .error = viewModel.phase {} else { XCTFail("empty reply should fail") }
    }

    func testThrownReplyDoesNotCallSuccess() async {
        var callbackCount = 0
        let driver = EngineDriver(
            runTurn: { _ in throw APIError.network("offline") },
            lastRawText: { "" }
        )
        let viewModel = QuickChatViewModel(
            phrases: [],
            suggestedTag: nil,
            progressStore: progressStore(),
            engineDriver: driver,
            onFirstValidAssistantReply: { callbackCount += 1; return true }
        )

        await viewModel.start()

        XCTAssertEqual(callbackCount, 0)
        if case .error = viewModel.phase {} else { XCTFail("network failure should fail") }
    }

    func testCancelledSessionDoesNotPublishOrConsumeLateReply() async {
        actor ReplyGate {
            var continuation: CheckedContinuation<ConversationEngine.TurnResult, Never>?
            func wait() async -> ConversationEngine.TurnResult {
                await withCheckedContinuation { continuation = $0 }
            }
            func isWaiting() -> Bool { continuation != nil }
            func finish() {
                continuation?.resume(returning: .init(dialog: "Too late", verdict: nil))
                continuation = nil
            }
        }
        let gate = ReplyGate()
        var callbackCount = 0
        let viewModel = QuickChatViewModel(
            phrases: [],
            suggestedTag: nil,
            progressStore: progressStore(),
            engineDriver: EngineDriver(
                runTurn: { _ in await gate.wait() },
                lastRawText: { "" }
            ),
            onFirstValidAssistantReply: { callbackCount += 1; return true }
        )
        let task = Task { await viewModel.start() }
        while !(await gate.isWaiting()) { await Task.yield() }

        viewModel.cancelSession()
        await gate.finish()
        await task.value

        XCTAssertEqual(callbackCount, 0)
        XCTAssertTrue(viewModel.turns.first?.assistantText.isEmpty ?? true)
    }

    func testDurableConsumeFailurePreventsReplyDisplay() async {
        let viewModel = QuickChatViewModel(
            phrases: [],
            suggestedTag: nil,
            progressStore: progressStore(),
            engineDriver: .stub(turns: [.init(dialog: "Do not display", verdict: nil)]),
            onFirstValidAssistantReply: { false }
        )

        await viewModel.start()

        XCTAssertTrue(viewModel.turns.first?.assistantText.isEmpty ?? true)
        if case .error = viewModel.phase {} else { XCTFail("durability failure should fail closed") }
    }

    func testConfirmedEndSynchronouslyRejectsLateReply() async {
        actor ReplyGate {
            var continuation: CheckedContinuation<ConversationEngine.TurnResult, Never>?
            func wait() async -> ConversationEngine.TurnResult {
                await withCheckedContinuation { continuation = $0 }
            }
            func isWaiting() -> Bool { continuation != nil }
            func finish() {
                continuation?.resume(returning: .init(dialog: "Too late", verdict: nil))
                continuation = nil
            }
        }
        let gate = ReplyGate()
        var callbackCount = 0
        let viewModel = QuickChatViewModel(
            phrases: [],
            suggestedTag: nil,
            progressStore: progressStore(),
            engineDriver: EngineDriver(
                runTurn: { _ in await gate.wait() },
                lastRawText: { "" }
            ),
            onFirstValidAssistantReply: { callbackCount += 1; return true }
        )
        let replyTask = Task { await viewModel.start() }
        while !(await gate.isWaiting()) { await Task.yield() }

        viewModel.prepareToEndSession()
        await gate.finish()
        await replyTask.value
        await viewModel.endSession()

        XCTAssertEqual(callbackCount, 0)
        XCTAssertTrue(viewModel.turns.first?.assistantText.isEmpty ?? true)
        XCTAssertEqual(viewModel.phase, .done)
    }
}
