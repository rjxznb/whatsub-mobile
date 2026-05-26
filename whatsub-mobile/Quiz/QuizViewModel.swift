import Foundation

@MainActor
final class QuizViewModel: ObservableObject {
    enum Phase: Equatable {
        case pickScope, loading, quizzing, insufficient, allMastered
        case error(String)
    }

    @Published private(set) var phase: Phase = .pickScope
    @Published private(set) var question: QuizQuestion?
    @Published private(set) var ruledOut: Set<String> = []
    @Published private(set) var revealed = false
    @Published private(set) var streak = 0
    @Published private(set) var masteredCount = 0
    @Published private(set) var poolCount = 0

    private var pool: [QuizCard] = []
    private let store: QuizProgressStore
    private var lastPhrase: String?

    init(store: QuizProgressStore = QuizProgressStore()) { self.store = store }

    /// Network path: fetch the scope's pool then start.
    func start(scope: QuizScope, token: String) async {
        phase = .loading
        do {
            let cards: [QuizCard]
            switch scope {
            case .publicCorpus:
                cards = try await WhatsubAPI.shared.browseCorpus(tags: [], token: token).compactMap(QuizCard.from)
            case .mine:
                cards = try await WhatsubAPI.shared.mineCorpus(tags: [], token: token).items.compactMap(QuizCard.from)
            }
            loadPool(cards)
        } catch {
            phase = scope == .publicCorpus
                ? .error("公共语料库需要授权后才能测验（可改用「我的」语料库）。")
                : .error("加载失败，请关闭后重试。")
        }
    }

    /// Testable entry: set the pool directly (no network) + begin.
    func loadPool(_ cards: [QuizCard]) {
        var seen = Set<String>(); var unique: [QuizCard] = []
        for c in cards where !seen.contains(c.phraseNormalized) { seen.insert(c.phraseNormalized); unique.append(c) }
        pool = unique
        poolCount = unique.count
        refreshStats()
        guard unique.count >= 4 else { phase = .insufficient; return }
        phase = .quizzing
        advance()
    }

    func answer(_ option: String) {
        guard let q = question, !revealed else { return }
        if option == q.correct {
            store.record(phrase: q.card.phraseNormalized, firstTryCorrect: ruledOut.isEmpty, wrongCount: ruledOut.count)
            streak = ruledOut.isEmpty ? streak + 1 : 0
            revealed = true
            refreshStats()
        } else {
            ruledOut.insert(option)
        }
    }

    func next() { advance() }

    func reset() {
        store.reset(scopePhrases: pool.map { $0.phraseNormalized })
        refreshStats()
        phase = .quizzing
        advance()
    }

    // MARK: - private
    private func advance() {
        let snap = store.snapshot()
        if !pool.isEmpty && pool.allSatisfy({ snap[$0.phraseNormalized]?.isMastered ?? false }) {
            question = nil; phase = .allMastered; return
        }
        var rng = SystemRandomNumberGenerator()
        guard let card = QuizSelection.next(pool: pool, progress: snap, exclude: lastPhrase, rng: &rng) else {
            phase = .insufficient; return
        }
        lastPhrase = card.phraseNormalized
        question = QuizQuestionBuilder.build(card: card, pool: pool, rng: &rng)
        ruledOut = []
        revealed = false
        phase = .quizzing
    }

    private func refreshStats() {
        masteredCount = store.masteredCount(in: pool.map { $0.phraseNormalized })
    }
}

extension QuizCard {
    static func from(_ p: BrowsePhrase) -> QuizCard? {
        guard let m = p.meaningZh, !m.isEmpty else { return nil }
        return QuizCard(phraseNormalized: p.phraseNormalized, phraseRaw: p.phraseRaw, meaningZh: m, usageNote: p.usageNote, contextSentence: nil)
    }
    static func from(_ m: MineItem) -> QuizCard? {
        guard let mean = m.meaningZh, !mean.isEmpty else { return nil }
        return QuizCard(phraseNormalized: m.phraseNormalized, phraseRaw: m.phraseRaw, meaningZh: mean, usageNote: m.usageNote, contextSentence: m.contextSentence)
    }
}
