import XCTest
@testable import whatsub_mobile

final class ProductionProgressStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("prod_test_\(UUID().uuidString).json")
    }

    func testEmptyOnMissingFile() {
        let store = ProductionProgressStore(fileURL: tempURL())
        XCTAssertNil(store.progress(for: "x"))
        XCTAssertEqual(store.snapshot().count, 0)
    }

    func testRecordCorrectIncrementsAndMastersAtThreshold() {
        let url = tempURL()
        let store = ProductionProgressStore(fileURL: url)
        let p = "bouncing-off-the-walls"
        store.recordCorrect(phrase: p, at: 1_000)
        let after1 = store.progress(for: p)!
        XCTAssertEqual(after1.usedCorrectCount, 1)
        XCTAssertEqual(after1.attemptCount, 1)
        XCTAssertNil(after1.masteredAt, "1 < threshold 2 → not yet mastered")

        store.recordCorrect(phrase: p, at: 2_000)
        let after2 = store.progress(for: p)!
        XCTAssertEqual(after2.usedCorrectCount, 2)
        XCTAssertEqual(after2.masteredAt, 2_000, "second correct crosses threshold; masteredAt = at")

        // Third correct does NOT reset masteredAt.
        store.recordCorrect(phrase: p, at: 3_000)
        XCTAssertEqual(store.progress(for: p)!.masteredAt, 2_000)
        try? FileManager.default.removeItem(at: url)
    }

    func testRecordWrongIncrementsAttemptAndStoresNote() {
        let store = ProductionProgressStore(fileURL: tempURL())
        store.recordWrong(phrase: "sort-it-out", note: "时态错误", at: 100)
        let p = store.progress(for: "sort-it-out")!
        XCTAssertEqual(p.usedCorrectCount, 0)
        XCTAssertEqual(p.attemptCount, 1)
        XCTAssertEqual(p.lastErrorNote, "时态错误")
    }

    func testRoundtripPersistsAcrossInstances() {
        let url = tempURL()
        do {
            let s = ProductionProgressStore(fileURL: url)
            s.recordCorrect(phrase: "fair-enough", at: 42)
            s.recordCorrect(phrase: "fair-enough", at: 43)  // mastered
        }
        let reloaded = ProductionProgressStore(fileURL: url)
        let p = reloaded.progress(for: "fair-enough")!
        XCTAssertEqual(p.usedCorrectCount, 2)
        XCTAssertEqual(p.masteredAt, 43)
        try? FileManager.default.removeItem(at: url)
    }

    func testIsDueForRepetition() {
        let store = ProductionProgressStore(fileURL: tempURL())
        let now: Double = 100 + ProductionProgress.spacedRepetitionWindow
        // Mastered long ago → due.
        store.recordCorrect(phrase: "a", at: 100)
        store.recordCorrect(phrase: "a", at: 100)
        XCTAssertTrue(store.isDueForRepetition(phrase: "a", now: now + 1))
        // Mastered very recently → not due.
        store.recordCorrect(phrase: "b", at: now)
        store.recordCorrect(phrase: "b", at: now)
        XCTAssertFalse(store.isDueForRepetition(phrase: "b", now: now + 10))
        // Not mastered yet → never "due" (it just stays in Tier1/Tier3).
        store.recordWrong(phrase: "c", note: "x", at: 100)
        XCTAssertFalse(store.isDueForRepetition(phrase: "c", now: now))
    }

    func testCorruptFileIsEmpty() {
        let url = tempURL()
        try? "garbage".data(using: .utf8)!.write(to: url)
        let store = ProductionProgressStore(fileURL: url)
        XCTAssertNil(store.progress(for: "x"))
        try? FileManager.default.removeItem(at: url)
    }
}
