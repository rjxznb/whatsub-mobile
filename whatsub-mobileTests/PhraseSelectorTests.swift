// whatsub-mobileTests/PhraseSelectorTests.swift
import XCTest
@testable import whatsub_mobile

final class PhraseSelectorTests: XCTestCase {

    /// Helper: build a MineItem with just the fields the selector cares about.
    private func mine(_ key: String, tags: [String] = []) -> MineItem {
        MineItem(phraseNormalized: key, phraseRaw: key, meaningZh: nil,
                 usageNote: nil, contextSentence: "...",
                 source: CorpusSource(kind: "webpage", url: "", title: nil, timestampSec: nil,
                                      libraryEntryId: nil, youtubeId: nil),
                 contributedAt: 0, tags: tags)
    }

    /// Helper: recognition predicate — returns true for the given set.
    private func rec(_ mastered: Set<String>) -> (String) -> Bool {
        { mastered.contains($0) }
    }

    func testColdStartReturnsNilWhenFewerThan3() {
        let result = PhraseSelector.pick(
            from: [mine("a"), mine("b")],
            isRecognized: { _ in true },
            productionMastered: { _ in false },
            isDueForRepetition: { _ in false },
            now: 0
        )
        XCTAssertNil(result, "spec §6.1 cold start: < 3 phrases → can't run")
    }

    func testTier1AllSameTagPicks3FromIt() {
        let items = [mine("a", tags: ["food"]), mine("b", tags: ["food"]),
                     mine("c", tags: ["food"]), mine("d", tags: ["work"])]
        let r = PhraseSelector.pick(
            from: items,
            isRecognized: rec(["a", "b", "c", "d"]),    // all recognized
            productionMastered: { _ in false },          // none produced
            isDueForRepetition: { _ in false },
            now: 0
        )!
        let keys = Set(r.phrases.map { $0.phraseNormalized })
        XCTAssertEqual(keys, ["a", "b", "c"], "Tier 1 same-tag bucket fills before crossing tag")
        XCTAssertEqual(r.suggestedTag, "food")
    }

    func testTier1IsHardEvenWhenTier3HasBetterTagCohesion() {
        // Tier1 spread across tags (no bucket ≥3); Tier3 all same tag.
        let items = [mine("a", tags: ["food"]), mine("b", tags: ["work"]),
                     mine("c", tags: ["travel"]),
                     // Tier3 same-tag cluster of 3 — TEMPTING but must be skipped:
                     mine("d", tags: ["food"]), mine("e", tags: ["food"]), mine("f", tags: ["food"])]
        let r = PhraseSelector.pick(
            from: items,
            isRecognized: rec(["a", "b", "c"]),       // a,b,c Tier1; d,e,f Tier3
            productionMastered: { _ in false },
            isDueForRepetition: { _ in false },
            now: 0
        )!
        let keys = Set(r.phrases.map { $0.phraseNormalized })
        let tier1Keys: Set<String> = ["a", "b", "c"]
        let fromTier1 = keys.intersection(tier1Keys).count
        XCTAssertGreaterThanOrEqual(fromTier1, 2,
            "spec §6.1: Tier 1 dominates the pick (≥2 of 3 slots) even when Tier 3 has a tighter tag bucket. Got picks: \(keys)")
    }

    func testTier1InsufficientFallsBackToTier3InTierOrder() {
        // Tier1 has only 1; pad with Tier3.
        let items = [mine("a"), mine("b"), mine("c"), mine("d")]
        let r = PhraseSelector.pick(
            from: items,
            isRecognized: rec(["a"]),                 // a is Tier1; b/c/d are Tier3
            productionMastered: { _ in false },
            isDueForRepetition: { _ in false },
            now: 0
        )!
        XCTAssertEqual(r.phrases.count, 3)
        XCTAssertTrue(r.phrases.map { $0.phraseNormalized }.contains("a"),
                      "Tier1 'a' must be in the picked set when present")
    }

    func testProducedAndNotDueIsExcluded() {
        let items = [mine("a"), mine("b"), mine("c"), mine("d")]
        let r = PhraseSelector.pick(
            from: items,
            isRecognized: rec(["a", "b", "c", "d"]),
            productionMastered: { $0 == "a" },        // a mastered
            isDueForRepetition: { _ in false },        // and not yet due
            now: 0
        )!
        XCTAssertFalse(r.phrases.map { $0.phraseNormalized }.contains("a"),
                       "spec §6.1 'excluded' tier: mastered + not-yet-due ⇒ skip")
    }

    func testProducedButDueGoesIntoTier2() {
        let items = [mine("a"), mine("b"), mine("c"), mine("d")]
        let r = PhraseSelector.pick(
            from: items,
            isRecognized: rec(["a", "b", "c", "d"]),
            productionMastered: { $0 == "a" },
            isDueForRepetition: { $0 == "a" },        // a is due for spaced repetition
            now: 0
        )!
        XCTAssertTrue(r.phrases.map { $0.phraseNormalized }.contains("a"),
                      "spec §6.1 Tier2: mastered AND due ⇒ candidate again")
    }
}
