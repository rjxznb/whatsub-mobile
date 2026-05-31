// whatsub-mobile/Practice/QuickChat/PhraseSelector.swift
import Foundation

/// Selects 3 phrases for one QuickChat session. Pure function — caller injects
/// recognition / production predicates so it's trivially testable.
///
/// Spec §6.1 priority (after spike-driven v2 patch):
///   Tier ordering = HARD constraint (Tier1 → Tier2 → Tier3, top wins).
///   Same-tag cohesion = SOFT bonus (prefer largest single-tag bucket).
///
/// Excluded: mastered phrases whose spaced-repetition window hasn't elapsed.
/// Cold start: returns nil when fewer than 3 candidates remain.
enum PhraseSelector {

    struct Pick {
        let phrases: [SessionPhrase]      // length == 3
        let suggestedTag: String?         // dominant shared tag if any; nil = LLM picks scene
    }

    /// Tier of a candidate.
    enum Tier: Int { case t1 = 1, t2 = 2, t3 = 3, excluded = 99 }

    /// Internal classification record. Hoisted to enum scope (not nested in
    /// `pick`) so the private helpers below can reference it.
    private struct Cand { let item: MineItem; let tier: Tier }

    /// Pure selector. Callers wire `isRecognized` from QuizProgressStore.isMastered
    /// and the production predicates from ProductionProgressStore.
    static func pick(
        from items: [MineItem],
        isRecognized: (String) -> Bool,
        productionMastered: (String) -> Bool,
        isDueForRepetition: (String) -> Bool,
        now: Double
    ) -> Pick? {
        guard items.count >= 3 else { return nil }   // cold start

        // 1. Classify every item into a tier.
        let classified: [Cand] = items.map { it in
            let key = it.phraseNormalized
            let recognized = isRecognized(key)
            let mastered = productionMastered(key)
            let due = isDueForRepetition(key)
            let tier: Tier
            if mastered && !due { tier = .excluded }
            else if mastered && due { tier = .t2 }
            else if recognized { tier = .t1 }            // recognized + not-yet-produced
            else { tier = .t3 }                          // new or unrecognized
            return Cand(item: it, tier: tier)
        }.filter { $0.tier != .excluded }

        guard classified.count >= 3 else { return nil }

        // 2. Try each tier in turn, finding the largest same-tag bucket within it.
        for targetTier in [Tier.t1, .t2, .t3] {
            let inTier = classified.filter { $0.tier == targetTier }
            if let (tag, bucket) = largestTagBucket(in: inTier), bucket.count >= 3 {
                return Pick(
                    phrases: Array(bucket.prefix(3)).map { sessionPhrase(from: $0.item) },
                    suggestedTag: tag
                )
            }
        }

        // 3. Cross-tag fallback (still tier-ordered): take Tier1 first, then Tier2, then Tier3.
        var picked: [Cand] = []
        for targetTier in [Tier.t1, .t2, .t3] {
            let inTier = classified.filter { $0.tier == targetTier }
            for c in inTier {
                if picked.count == 3 { break }
                if !picked.contains(where: { $0.item.phraseNormalized == c.item.phraseNormalized }) {
                    picked.append(c)
                }
            }
            if picked.count == 3 { break }
        }
        guard picked.count == 3 else { return nil }

        // 4. Try to give the LLM a suggested tag if 2+ of the picked items share one.
        let suggested = dominantTag(of: picked.map { $0.item.tags })
        return Pick(phrases: picked.map { sessionPhrase(from: $0.item) },
                    suggestedTag: suggested)
    }

    // ---- helpers ----

    /// (tag, candidates-with-that-tag) for the largest single-tag cluster.
    private static func largestTagBucket(in cands: [Cand]) -> (String, [Cand])? {
        var buckets: [String: [Cand]] = [:]
        for c in cands {
            for t in c.item.tags {
                buckets[t, default: []].append(c)
            }
        }
        return buckets.max(by: { $0.value.count < $1.value.count }).map { ($0.key, $0.value) }
    }

    /// If a majority of the picked items share one tag, return it. Else nil
    /// (= let the LLM invent a scenario).
    private static func dominantTag(of tagsList: [[String]]) -> String? {
        var counts: [String: Int] = [:]
        for tags in tagsList { for t in tags { counts[t, default: 0] += 1 } }
        let majority = (tagsList.count / 2) + 1     // > half
        return counts.filter { $0.value >= majority }.max(by: { $0.value < $1.value })?.key
    }

    private static func sessionPhrase(from m: MineItem) -> SessionPhrase {
        SessionPhrase(
            phraseNormalized: m.phraseNormalized,
            phraseRaw: m.phraseRaw,
            meaningZh: m.meaningZh,
            usageNote: m.usageNote,
            contextSentence: m.contextSentence,
            sourceKind: m.source.kind,
            sourceURL: m.source.url,
            sourceTimestampSec: m.source.timestampSec,
            tags: m.tags
        )
    }
}
