import XCTest
@testable import whatsub_mobile

@MainActor
final class QuizViewModelTests: XCTestCase {
    private func tempStore() -> QuizProgressStore {
        QuizProgressStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("vm_\(UUID().uuidString).json"))
    }
    private func cards(_ n: Int) -> [QuizCard] {
        (0..<n).map { QuizCard(phraseNormalized: "p\($0)", phraseRaw: "raw\($0)", meaningZh: "意\($0)", usageNote: nil, contextSentence: nil) }
    }

    func testInsufficientPool() {
        let vm = QuizViewModel(store: tempStore())
        vm.loadPool(cards(3))
        XCTAssertEqual(vm.phase, .insufficient)
    }

    func testLoadPoolStartsQuizWithValidQuestion() {
        let vm = QuizViewModel(store: tempStore())
        vm.loadPool(cards(5))
        XCTAssertEqual(vm.phase, .quizzing)
        let q = try? XCTUnwrap(vm.question)
        XCTAssertTrue(q!.options.contains(q!.correct))
    }

    func testWrongThenCorrectRecordsNotFirstTry() {
        let store = tempStore()
        let vm = QuizViewModel(store: store)
        vm.loadPool(cards(5))
        let q = vm.question!
        let wrong = q.options.first { $0 != q.correct }!
        vm.answer(wrong)
        XCTAssertTrue(vm.ruledOut.contains(wrong))
        XCTAssertFalse(vm.revealed)
        vm.answer(q.correct)
        XCTAssertTrue(vm.revealed)
        XCTAssertEqual(vm.streak, 0) // had a wrong → streak resets
        XCTAssertEqual(store.progress(for: q.card.phraseNormalized).correctFirstTry, 0)
        XCTAssertEqual(store.progress(for: q.card.phraseNormalized).wrong, 1)
    }

    func testFirstTryCorrectIncrementsStreakAndMastery() {
        let store = tempStore()
        let vm = QuizViewModel(store: store)
        vm.loadPool(cards(5))
        let id = vm.question!.card.phraseNormalized
        vm.answer(vm.question!.correct)
        XCTAssertTrue(vm.revealed)
        XCTAssertEqual(vm.streak, 1)
        XCTAssertEqual(store.progress(for: id).correctFirstTry, 1)
    }
}
