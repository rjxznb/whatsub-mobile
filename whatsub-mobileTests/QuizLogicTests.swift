import XCTest
@testable import whatsub_mobile

final class QuizLogicTests: XCTestCase {
    private func card(_ id: String, _ meaning: String) -> QuizCard {
        QuizCard(phraseNormalized: id, phraseRaw: id, meaningZh: meaning, usageNote: nil, contextSentence: nil)
    }
    private var rng = SystemRandomNumberGenerator()

    func testBuildQuestionContainsCorrectAndDistinctDistractors() {
        let pool = [card("a","甲"), card("b","乙"), card("c","丙"), card("d","丁"), card("e","戊")]
        let q = QuizQuestionBuilder.build(card: pool[0], pool: pool, rng: &rng)
        XCTAssertEqual(q.correct, "甲")
        XCTAssertTrue(q.options.contains("甲"))
        XCTAssertEqual(Set(q.options).count, q.options.count) // all distinct
        XCTAssertLessThanOrEqual(q.options.count, 4)
        XCTAssertEqual(q.options.filter { $0 == "甲" }.count, 1) // correct appears once
        XCTAssertFalse(q.options.dropFirst(0).filter { $0 != "甲" }.contains("甲"))
    }

    func testBuildQuestionDistractorsNeverEqualCorrect() {
        // pool where many share the correct meaning → distractors must exclude it
        let pool = [card("a","同"), card("b","同"), card("c","异1"), card("d","异2")]
        let q = QuizQuestionBuilder.build(card: pool[0], pool: pool, rng: &rng)
        XCTAssertEqual(q.options.filter { $0 == "同" }.count, 1)
    }

    func testBucketClassification() {
        XCTAssertEqual(QuizSelection.bucket(nil), .fresh)                              // unseen
        XCTAssertEqual(QuizSelection.bucket(QuizProgress(seen: 1, correctFirstTry: 0, wrong: 1, lastSeenAt: 0)), .fresh) // wrong → drill
        XCTAssertEqual(QuizSelection.bucket(QuizProgress(seen: 1, correctFirstTry: 1, wrong: 0, lastSeenAt: 0)), .learning)
        XCTAssertEqual(QuizSelection.bucket(QuizProgress(seen: 2, correctFirstTry: 2, wrong: 0, lastSeenAt: 0)), .mastered)
    }

    func testSelectionPrefersFreshOverMastered() {
        let pool = [card("m","掌"), card("f","新")]
        let progress: [String: QuizProgress] = [
            "m": QuizProgress(seen: 5, correctFirstTry: 5, wrong: 0, lastSeenAt: 0) // mastered
        ]
        // "f" is unseen (fresh) → must be picked over the mastered "m"
        let pick = QuizSelection.next(pool: pool, progress: progress, exclude: nil, rng: &rng)
        XCTAssertEqual(pick?.phraseNormalized, "f")
    }

    func testSelectionExcludesLastWhenAlternativesExist() {
        let pool = [card("a","甲"), card("b","乙")]
        let pick = QuizSelection.next(pool: pool, progress: [:], exclude: "a", rng: &rng)
        XCTAssertEqual(pick?.phraseNormalized, "b")
    }
}
