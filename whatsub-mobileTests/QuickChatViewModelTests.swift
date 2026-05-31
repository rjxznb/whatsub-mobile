import XCTest
@testable import whatsub_mobile

@MainActor
final class QuickChatViewModelTests: XCTestCase {

    private func phrase(_ raw: String) -> SessionPhrase {
        SessionPhrase(phraseNormalized: raw, phraseRaw: raw, meaningZh: nil,
                      usageNote: nil, contextSentence: "", sourceKind: "webpage",
                      sourceURL: "", sourceTimestampSec: nil, tags: [])
    }

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vmtest_\(UUID().uuidString).json")
    }

    func testInitialPhaseIsThinkingThenIdleAfterOpenTurn() async throws {
        let storeURL = tempStoreURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: storeURL) }
        let store = ProductionProgressStore(fileURL: storeURL)
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: [
                // Opening turn — assistant says "Hi.", no verdict yet.
                .init(events: [.dialogDelta("Hi."), .sentence("Hi."),
                               .verdict(TurnVerdict(verdicts: [
                                   .init(phrase: "a", attempted: false, correct: false, note: ""),
                                   .init(phrase: "b", attempted: false, correct: false, note: ""),
                                   .init(phrase: "c", attempted: false, correct: false, note: ""),
                               ])), .finished])
            ]),
            now: { 100 }
        )
        await vm.start()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.turns.count, 1)
        XCTAssertEqual(vm.turns[0].assistantText, "Hi.")
        XCTAssertTrue(vm.completedPhrases.isEmpty)
    }

    func testCorrectVerdictAddsToSessionSetAndPlaysFeedback() async throws {
        let storeURL = tempStoreURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: storeURL) }
        let store = ProductionProgressStore(fileURL: storeURL)
        let verdict = TurnVerdict(verdicts: [
            .init(phrase: "a", attempted: true, correct: true, note: ""),
            .init(phrase: "b", attempted: false, correct: false, note: ""),
            .init(phrase: "c", attempted: false, correct: false, note: ""),
        ])
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: [
                .init(events: [.finished]),                                  // opening
                .init(events: [.verdict(verdict), .finished]),               // user turn 1
            ]),
            now: { 100 }
        )
        await vm.start()
        await vm.submitUserInput("I'm a using it.")
        XCTAssertEqual(vm.completedPhrases, ["a"])
    }

    func testCumulativeDriftDoesNotDoubleCountInStore() async throws {
        // LLM mis-marks "a" correct in turn 2 even though user didn't use it.
        // The session-Set already contains "a" from turn 1, so the store should
        // record only ONE +1 for "a" (not two).
        let storeURL = tempStoreURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: storeURL) }
        let store = ProductionProgressStore(fileURL: storeURL)
        let correctA = TurnVerdict(verdicts: [
            .init(phrase: "a", attempted: true, correct: true, note: ""),
            .init(phrase: "b", attempted: false, correct: false, note: ""),
            .init(phrase: "c", attempted: false, correct: false, note: ""),
        ])
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: [
                .init(events: [.finished]),                          // opening
                .init(events: [.verdict(correctA), .finished]),      // turn 1
                .init(events: [.verdict(correctA), .finished]),      // turn 2 — same flag (drift)
            ]),
            now: { 100 }
        )
        await vm.start()
        await vm.submitUserInput("a a a")
        await vm.submitUserInput("xyz")
        XCTAssertEqual(vm.completedPhrases, ["a"])
        await vm.endSession()
        XCTAssertEqual(store.progress(for: "a")?.usedCorrectCount, 1,
                       "session-Set guarantees at most +1 per phrase per session")
    }

    func testEndOnTurn5HardCap() async throws {
        let storeURL = tempStoreURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: storeURL) }
        let store = ProductionProgressStore(fileURL: storeURL)
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: Array(repeating: .init(events: [.finished]), count: 6)),
            now: { 100 }
        )
        await vm.start()                          // turn 0 (opening)
        for _ in 1...4 { await vm.submitUserInput("x") }    // turns 1..4
        XCTAssertEqual(vm.phase, .idle, "still going at turn 4")
        await vm.submitUserInput("x")             // turn 5 — auto-end
        XCTAssertEqual(vm.phase, .done, "5-turn hard cap (spec §9 #4)")
    }

    func testUnlimitedTurnsDoesNotEndOnTurn5() async throws {
        let storeURL = tempStoreURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: storeURL) }
        let store = ProductionProgressStore(fileURL: storeURL)
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: Array(repeating: .init(events: [.finished]), count: 10)),
            maxTurns: nil,      // ← unlimited
            now: { 100 }
        )
        await vm.start()
        for _ in 1...8 { await vm.submitUserInput("x") }
        XCTAssertEqual(vm.phase, .idle, "unlimited cap: 8 user turns must not auto-end")
        XCTAssertNotEqual(vm.phase, .done)
    }

    func testExitMidSessionPersistsAccumulatedVerdicts() async throws {
        let storeURL = tempStoreURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: storeURL) }
        let store = ProductionProgressStore(fileURL: storeURL)
        let correctA = TurnVerdict(verdicts: [
            .init(phrase: "a", attempted: true, correct: true, note: ""),
            .init(phrase: "b", attempted: false, correct: false, note: ""),
            .init(phrase: "c", attempted: false, correct: false, note: ""),
        ])
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: [
                .init(events: [.finished]),
                .init(events: [.verdict(correctA), .finished]),
            ]),
            now: { 100 }
        )
        await vm.start()
        await vm.submitUserInput("hi")
        // User taps "关闭" — simulate via endSession before normal completion.
        await vm.endSession()
        XCTAssertEqual(store.progress(for: "a")?.usedCorrectCount, 1,
                       "spec §6.5.1: mid-session exit must not lose verdicts")
    }
}
