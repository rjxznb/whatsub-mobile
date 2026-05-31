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

    struct Pick: Identifiable {
        // Concatenated phrase keys make a stable id without an extra field.
        // Two different picks (different phrase sets) will get different ids
        // and SwiftUI's .sheet(item:) treats them as distinct, which is what
        // we want (a new session = a new sheet identity).
        var id: String { phrases.map { $0.phraseNormalized }.joined(separator: "|") }
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
        guard items.count >= 3 else { return nil }

        // 1. Classify (unchanged).
        let classified: [Cand] = items.map { it in
            let key = it.phraseNormalized
            let recognized = isRecognized(key)
            let mastered = productionMastered(key)
            let due = isDueForRepetition(key)
            let tier: Tier
            if mastered && !due { tier = .excluded }
            else if mastered && due { tier = .t2 }
            else if recognized { tier = .t1 }
            else { tier = .t3 }
            return Cand(item: it, tier: tier)
        }.filter { $0.tier != .excluded }

        guard classified.count >= 3 else { return nil }

        let t1 = classified.filter { $0.tier == .t1 }
        let t2 = classified.filter { $0.tier == .t2 }
        let t3 = classified.filter { $0.tier == .t3 }

        // 2. Tier 1 has a same-tag bucket ≥3 → use it.
        if t1.count >= 3, let (tag, bucket) = largestTagBucket(in: t1), bucket.count >= 3 {
            return Pick(
                phrases: Array(bucket.prefix(3)).map { sessionPhrase(from: $0.item) },
                suggestedTag: tag
            )
        }

        // 3. Tier 1 has 2+ items: take 2 from Tier 1, 1 from Tier 2/3 (same-tag preferred).
        if t1.count >= 2 {
            // Pick 2 Tier-1 items, preferring same-tag pairs.
            let pair = bestSameTagPair(in: t1) ?? Array(t1.prefix(2))
            // 3rd slot: Tier 2 first, then Tier 3, then fall back to Tier 1.
            let preferTags = Set(pair.flatMap { $0.item.tags })
            let third: Cand
            if let t2pick = pickPreferringTags(from: t2, prefer: preferTags) {
                third = t2pick
            } else if let t3pick = pickPreferringTags(from: t3, prefer: preferTags) {
                third = t3pick
            } else if t1.count >= 3 {
                // Tier 2/3 both empty — fall back to a 3rd Tier-1 item not already picked.
                let pickedKeys = Set(pair.map { $0.item.phraseNormalized })
                if let extra = t1.first(where: { !pickedKeys.contains($0.item.phraseNormalized) }) {
                    third = extra
                } else {
                    return nil   // shouldn't happen given t1.count >= 3
                }
            } else {
                return nil   // not enough material
            }
            let picked = pair + [third]
            let suggested = dominantTag(of: picked.map { $0.item.tags })
            return Pick(phrases: picked.map { sessionPhrase(from: $0.item) },
                        suggestedTag: suggested)
        }

        // 4. Tier 1 has 0 or 1 items: cross-tag tier-order fill.
        var picked: [Cand] = []
        for tier in [t1, t2, t3] {
            for c in tier {
                if picked.count == 3 { break }
                if !picked.contains(where: { $0.item.phraseNormalized == c.item.phraseNormalized }) {
                    picked.append(c)
                }
            }
            if picked.count == 3 { break }
        }
        guard picked.count == 3 else { return nil }
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

    // ---- additional helpers ----

    /// Returns 2 Tier-1 items sharing a tag, if any pair exists; otherwise nil.
    private static func bestSameTagPair(in cands: [Cand]) -> [Cand]? {
        for c1 in cands {
            for c2 in cands where c2.item.phraseNormalized != c1.item.phraseNormalized {
                if !Set(c1.item.tags).isDisjoint(with: c2.item.tags) {
                    return [c1, c2]
                }
            }
        }
        return nil
    }

    /// Picks one item from `pool`, preferring items whose tags intersect `prefer`.
    /// Returns nil if pool is empty.
    private static func pickPreferringTags(from pool: [Cand], prefer: Set<String>) -> Cand? {
        if pool.isEmpty { return nil }
        if !prefer.isEmpty,
           let match = pool.first(where: { !Set($0.item.tags).isDisjoint(with: prefer) }) {
            return match
        }
        return pool.first
    }
}
