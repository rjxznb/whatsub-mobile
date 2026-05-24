import XCTest
@testable import whatsub_mobile

final class QuizProgressStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("quiz_test_\(UUID().uuidString).json")
    }

    func testRecordPersistsAndReloads() {
        let url = tempURL()
        do {
            let store = QuizProgressStore(fileURL: url)
            store.record(phrase: "p1", firstTryCorrect: true, wrongCount: 0)
            store.record(phrase: "p1", firstTryCorrect: false, wrongCount: 2)
        }
        let reloaded = QuizProgressStore(fileURL: url) // fresh instance reads the file
        let p = reloaded.progress(for: "p1")
        XCTAssertEqual(p.seen, 2)
        XCTAssertEqual(p.correctFirstTry, 1)
        XCTAssertEqual(p.wrong, 2)
        try? FileManager.default.removeItem(at: url)
    }

    func testMissingFileIsEmpty() {
        let store = QuizProgressStore(fileURL: tempURL())
        XCTAssertEqual(store.progress(for: "x"), QuizProgress())
        XCTAssertEqual(store.masteredCount(in: ["x"]), 0)
    }

    func testCorruptFileIsEmpty() {
        let url = tempURL()
        try? "not json".data(using: .utf8)!.write(to: url)
        let store = QuizProgressStore(fileURL: url)
        XCTAssertEqual(store.progress(for: "x"), QuizProgress())
        try? FileManager.default.removeItem(at: url)
    }

    func testMasteredCountAndReset() {
        let url = tempURL()
        let store = QuizProgressStore(fileURL: url)
        store.record(phrase: "m", firstTryCorrect: true, wrongCount: 0)
        store.record(phrase: "m", firstTryCorrect: true, wrongCount: 0) // correctFirstTry=2 → mastered
        XCTAssertEqual(store.masteredCount(in: ["m", "other"]), 1)
        store.reset(scopePhrases: ["m"])
        XCTAssertEqual(store.masteredCount(in: ["m"]), 0)
        try? FileManager.default.removeItem(at: url)
    }
}
