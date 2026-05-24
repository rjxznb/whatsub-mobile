import Foundation

/// Which corpus the quiz draws from (chosen per run).
enum QuizScope { case publicCorpus, mine }

/// A unified quiz card from either the public (BrowsePhrase) or personal (MineItem) corpus.
struct QuizCard: Identifiable, Equatable {
    let phraseNormalized: String
    let phraseRaw: String
    let meaningZh: String
    let usageNote: String?
    let contextSentence: String?
    var id: String { phraseNormalized }
}

/// Persistent per-phrase progress.
struct QuizProgress: Codable, Equatable {
    var seen: Int = 0
    var correctFirstTry: Int = 0
    var wrong: Int = 0
    var lastSeenAt: Int64 = 0
    var isMastered: Bool { correctFirstTry >= 2 }
}

/// One quiz question: the card under test + shuffled option texts (one == card.meaningZh).
struct QuizQuestion: Equatable {
    let card: QuizCard
    let options: [String]
    var correct: String { card.meaningZh }
}

enum QuizSelection {
    enum Bucket: Int { case fresh = 0, learning = 1, mastered = 2 }

    /// fresh = unseen OR previously-wrong (drill); learning = seen, not mastered, no wrong; mastered = correctFirstTry>=2.
    static func bucket(_ p: QuizProgress?) -> Bucket {
        guard let p = p, p.seen > 0 else { return .fresh }
        if p.isMastered { return .mastered }
        if p.wrong > 0 { return .fresh }
        return .learning
    }

    /// Pick from the first non-empty bucket (fresh→learning→mastered), random within it,
    /// avoiding `exclude` unless it's the only card.
    static func next<G: RandomNumberGenerator>(
        pool: [QuizCard], progress: [String: QuizProgress], exclude: String?, rng: inout G
    ) -> QuizCard? {
        let filtered = pool.filter { $0.phraseNormalized != exclude }
        let usable = filtered.isEmpty ? pool : filtered
        guard !usable.isEmpty else { return nil }
        for b in [Bucket.fresh, .learning, .mastered] {
            let inBucket = usable.filter { bucket(progress[$0.phraseNormalized]) == b }
            if let pick = inBucket.randomElement(using: &rng) { return pick }
        }
        return usable.randomElement(using: &rng)
    }
}

enum QuizQuestionBuilder {
    /// Build a question: correct = card.meaningZh; up to 3 distinct distractor meanings (!= correct); shuffled.
    static func build<G: RandomNumberGenerator>(
        card: QuizCard, pool: [QuizCard], rng: inout G
    ) -> QuizQuestion {
        let correct = card.meaningZh
        var distractors = Array(Set(pool.map { $0.meaningZh })).filter { $0 != correct }
        distractors.shuffle(using: &rng)
        var options = [correct] + Array(distractors.prefix(3))
        options.shuffle(using: &rng)
        return QuizQuestion(card: card, options: options)
    }
}
