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
            onFirstValidAssistantReply: { callbackCount += 1 }
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
            onFirstValidAssistantReply: { callbackCount += 1 }
        )

        await viewModel.start()

        XCTAssertEqual(callbackCount, 0)
        if case .error = viewModel.phase {} else { XCTFail("network failure should fail") }
    }
}
