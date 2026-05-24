# Corpus Quiz (单词卡测验) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iOS flashcard quiz over corpus phrases — pick a scope (公共/个人), answer 英→中 multiple-choice (wrong → ✗ + retry, correct → inline reveal), with persistent local progress + weighted selection.

**Architecture:** Pure-Swift, client-side only (reuses `WhatsubAPI.browseCorpus`/`mineCorpus`; no backend change). Logic split into a testable model layer (`QuizModels` pure functions + `QuizProgressStore` file persistence) and a `@MainActor QuizViewModel` that the `QuizView` renders. Entry from a button atop the 语料库 tab.

**Tech Stack:** SwiftUI (iOS 16 deployment target — NO iOS 17 APIs), XCTest (runs in CI). Built in CI (can't compile on Windows).

**Spec:** `docs/superpowers/specs/2026-05-24-corpus-quiz-design.md`

**iOS-16 API guardrail (applies to every view task):** do NOT use `.navigationDestination(item:)`, `.toolbar { ToolbarItem(placement: .topBarLeading) }`, or `Observation`/`@Observable` — all iOS 17+. Use `.navigationDestination(for: String.self)` + `NavigationLink(value:)`, and `.navigationBarLeading` placement. The project deploys to iOS 16; an iOS-17-only symbol is a hard compile error.

**Branch + push:** all work on `feat/ios-corpus-quiz` (spec already committed there). Commit LOCALLY per task; the controller pushes once at the end (Task 6) → triggers CI + TestFlight.

---

## File Structure

- Create `whatsub-mobile/Quiz/QuizModels.swift` — `QuizScope`, `QuizCard`, `QuizProgress`, `QuizQuestion`, and the pure helpers `QuizSelection` + `QuizQuestionBuilder`. No UIKit/SwiftUI, no I/O → trivially unit-testable.
- Create `whatsub-mobile/Quiz/QuizProgressStore.swift` — JSON file persistence (`Documents/quiz_progress.json`), injectable file URL for tests.
- Create `whatsub-mobile/Quiz/QuizViewModel.swift` — `@MainActor ObservableObject`; fetch (API) + state machine + delegates to the pure helpers + store. Includes `QuizCard.from(_:)` mappers.
- Create `whatsub-mobile/Quiz/QuizView.swift` — the SwiftUI screen.
- Modify `whatsub-mobile/Corpus/CorpusView.swift` — add the entry button + present `QuizView` as a sheet.
- Test `whatsub-mobileTests/QuizLogicTests.swift` — `QuizQuestionBuilder` + `QuizSelection`.
- Test `whatsub-mobileTests/QuizProgressStoreTests.swift` — store round-trip / record / corrupt / reset.
- Test `whatsub-mobileTests/QuizViewModelTests.swift` — `loadPool` + `answer` + `next` flow with an injected temp-file store.

(The `whatsub-mobileTests` target already exists and globs the dir — new test files are picked up automatically. The module is imported as `@testable import whatsub_mobile`.)

---

## Task 1: Quiz models + pure logic (TDD)

**Files:**
- Create: `whatsub-mobile/Quiz/QuizModels.swift`
- Test: `whatsub-mobileTests/QuizLogicTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `whatsub-mobileTests/QuizLogicTests.swift`:
```swift
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
```

- [ ] **Step 2: Run to verify failure**

These run in CI (can't compile on Windows). Locally just confirm the symbols don't exist yet, then implement.

- [ ] **Step 3: Implement `QuizModels.swift`**

```swift
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
```

- [ ] **Step 4: Commit (LOCAL)**

```bash
git add whatsub-mobile/Quiz/QuizModels.swift whatsub-mobileTests/QuizLogicTests.swift
git commit -m "feat(quiz): models + pure selection/question logic"
```

---

## Task 2: Progress store (TDD)

**Files:**
- Create: `whatsub-mobile/Quiz/QuizProgressStore.swift`
- Test: `whatsub-mobileTests/QuizProgressStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `whatsub-mobileTests/QuizProgressStoreTests.swift`:
```swift
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
```

- [ ] **Step 2: Run to verify failure** (CI; symbol missing locally).

- [ ] **Step 3: Implement `QuizProgressStore.swift`**

```swift
import Foundation

/// Persistent per-phrase quiz progress, stored as JSON in the app's Documents dir.
/// Written immediately after each completed phrase (atomic) so an app kill never loses it.
final class QuizProgressStore {
    private let fileURL: URL
    private var phrases: [String: QuizProgress]

    init(fileURL: URL = QuizProgressStore.defaultURL) {
        self.fileURL = fileURL
        self.phrases = QuizProgressStore.loadFrom(fileURL)
    }

    static var defaultURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("quiz_progress.json")
    }

    func progress(for phrase: String) -> QuizProgress { phrases[phrase] ?? QuizProgress() }
    func snapshot() -> [String: QuizProgress] { phrases }
    func masteredCount(in pool: [String]) -> Int { pool.filter { phrases[$0]?.isMastered ?? false }.count }

    func record(phrase: String, firstTryCorrect: Bool, wrongCount: Int) {
        var p = phrases[phrase] ?? QuizProgress()
        p.seen += 1
        if firstTryCorrect { p.correctFirstTry += 1 }
        p.wrong += wrongCount
        p.lastSeenAt = Int64(Date().timeIntervalSince1970 * 1000)
        phrases[phrase] = p
        save()
    }

    func reset(scopePhrases: [String]) {
        for k in scopePhrases { phrases[k] = nil }
        save()
    }

    // MARK: - Persistence
    private struct FileShape: Codable { var version: Int; var phrases: [String: QuizProgress] }

    private func save() {
        let shape = FileShape(version: 1, phrases: phrases)
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: fileURL, options: .atomic) // .atomic = temp file + rename
    }

    private static func loadFrom(_ url: URL) -> [String: QuizProgress] {
        guard let data = try? Data(contentsOf: url),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data) else { return [:] }
        return shape.phrases
    }
}
```

- [ ] **Step 4: Commit (LOCAL)**

```bash
git add whatsub-mobile/Quiz/QuizProgressStore.swift whatsub-mobileTests/QuizProgressStoreTests.swift
git commit -m "feat(quiz): persistent local progress store"
```

---

## Task 3: View model (TDD for the sync logic)

**Files:**
- Create: `whatsub-mobile/Quiz/QuizViewModel.swift`
- Test: `whatsub-mobileTests/QuizViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `whatsub-mobileTests/QuizViewModelTests.swift`:
```swift
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
```

- [ ] **Step 2: Run to verify failure** (CI).

- [ ] **Step 3: Implement `QuizViewModel.swift`**

```swift
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
                cards = try await WhatsubAPI.shared.mineCorpus(tags: [], token: token).compactMap(QuizCard.from)
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
```

- [ ] **Step 4: Commit (LOCAL)**

```bash
git add whatsub-mobile/Quiz/QuizViewModel.swift whatsub-mobileTests/QuizViewModelTests.swift
git commit -m "feat(quiz): view model (scope fetch + answer/select state machine)"
```

---

## Task 4: Quiz screen (CI-compiled, manual-verified)

**Files:**
- Create: `whatsub-mobile/Quiz/QuizView.swift`

No unit test (SwiftUI view). Verified by CI compile + manual run.

- [ ] **Step 1: Implement `QuizView.swift`**

iOS-16 APIs only. Note: `NavigationLink(value:)` + `.navigationDestination(for: String.self)` for the optional detail link; `.navigationBarLeading` placement for the close button.

```swift
import SwiftUI

struct QuizView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = QuizViewModel()
    @Environment(\.dismiss) private var dismiss

    private var token: String? { appState.session?.sessionToken }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                switch vm.phase {
                case .pickScope: scopePicker
                case .loading: ProgressView().tint(.whatsubAccent)
                case .insufficient:
                    centered(icon: "tray", title: "短语不够测验", sub: "该语料库至少需要 4 个有释义的短语")
                case .allMastered: allMasteredBody
                case .error(let m): centered(icon: "exclamationmark.triangle", title: m, sub: "")
                case .quizzing: quizBody
                }
            }
            .navigationTitle("单词卡测验")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() }.tint(.whatsubAccent) } }
            .navigationDestination(for: String.self) { PhraseDetailView(phrase: $0) }
        }
    }

    private var scopePicker: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.play").font(.system(size: 48)).foregroundStyle(.whatsubAccent)
            Text("选择测验范围").font(.headline).foregroundStyle(.whatsubInk)
            Button { startScope(.publicCorpus) } label: { scopeLabel("公共语料库") }
            Button { startScope(.mine) } label: { scopeLabel("我的语料库") }
            Spacer()
        }.padding(32)
    }

    private func scopeLabel(_ t: String) -> some View {
        Text(t).fontWeight(.semibold).frame(maxWidth: .infinity).padding()
            .background(Color.whatsubAccent).foregroundStyle(.black).cornerRadius(12)
    }

    @ViewBuilder private var quizBody: some View {
        if let q = vm.question {
            VStack(spacing: 16) {
                header
                Text(q.card.phraseRaw)
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(.whatsubInk)
                    .multilineTextAlignment(.center).padding(.horizontal).padding(.top, 8)
                ForEach(q.options, id: \.self) { opt in optionButton(q, opt) }
                if vm.revealed { revealPanel(q) }
                Spacer()
            }.padding(20)
        }
    }

    private var header: some View {
        HStack {
            Text("已掌握 \(vm.masteredCount)/\(vm.poolCount)").font(.caption).foregroundStyle(.whatsubInkMuted)
            Spacer()
            if vm.streak > 0 { Text("连对 \(vm.streak) 🔥").font(.caption).foregroundStyle(.whatsubAccent) }
        }
    }

    private func optionButton(_ q: QuizQuestion, _ opt: String) -> some View {
        let isWrong = vm.ruledOut.contains(opt)
        let isCorrectRevealed = vm.revealed && opt == q.correct
        return Button { vm.answer(opt) } label: {
            HStack {
                Text(opt).foregroundStyle(.whatsubInk).multilineTextAlignment(.leading)
                Spacer()
                if isWrong { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                if isCorrectRevealed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isCorrectRevealed ? Color.green.opacity(0.15)
                    : isWrong ? Color.red.opacity(0.12)
                    : Color.whatsubBgElev,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .disabled(isWrong || vm.revealed)
    }

    private func revealPanel(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(q.card.meaningZh).font(.headline).foregroundStyle(.whatsubInk)
            if let u = q.card.usageNote, !u.isEmpty {
                Text(u).font(.subheadline).foregroundStyle(.whatsubInkSoft)
            }
            if let c = q.card.contextSentence, !c.isEmpty {
                Text(c).font(.caption).foregroundStyle(.whatsubInkMuted)
            }
            NavigationLink("看完整详情", value: q.card.phraseNormalized)
                .font(.caption).tint(.whatsubAccent)
            Button { vm.next() } label: {
                Text("继续").fontWeight(.semibold).frame(maxWidth: .infinity).padding()
                    .background(Color.whatsubAccent).foregroundStyle(.black).cornerRadius(12)
            }.padding(.top, 4)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    private var allMasteredBody: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("🎉").font(.system(size: 60))
            Text("本库已全部掌握").font(.headline).foregroundStyle(.whatsubInk)
            Button("重置本库进度") { vm.reset() }.buttonStyle(.bordered).tint(.whatsubAccent)
            Spacer()
        }.padding(32)
    }

    private func centered(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.whatsubAccent)
            Text(title).font(.headline).foregroundStyle(.whatsubInk).multilineTextAlignment(.center)
            if !sub.isEmpty {
                Text(sub).font(.footnote).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
            }
            Spacer()
        }.padding(32)
    }

    private func startScope(_ s: QuizScope) {
        guard let t = token else { return }
        Task { await vm.start(scope: s, token: t) }
    }
}
```

- [ ] **Step 2: Commit (LOCAL)**

```bash
git add whatsub-mobile/Quiz/QuizView.swift
git commit -m "feat(quiz): QuizView screen (scope pick, MC card, reveal, progress header)"
```

---

## Task 5: 语料库 entry button (CI-compiled, manual-verified)

**Files:**
- Modify: `whatsub-mobile/Corpus/CorpusView.swift`

- [ ] **Step 1: Add the sheet state + entry button**

In `CorpusView`, add a state var near the top of the struct (after `private var token`):
```swift
    @State private var showQuiz = false
```

Add the entry button right under the "语料库" title `Text(...)` block (after line ~16, before the `Picker`). Replace the title block so the title row carries a trailing 单词卡测验 button:
```swift
                HStack {
                    Text("语料库")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.whatsubInk)
                    Spacer()
                    Button { showQuiz = true } label: {
                        Label("单词卡", systemImage: "rectangle.stack.badge.play")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.whatsubAccent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)
```
(This replaces the existing standalone `Text("语料库") … .padding(...)` block.)

Add the sheet modifier on the outer `VStack` — put it alongside the existing `.task`/`.refreshable` (after `.refreshable { ... }`):
```swift
            .sheet(isPresented: $showQuiz) {
                QuizView().environmentObject(appState)
            }
```
(`.environmentObject(appState)` is passed explicitly so `QuizView` has the session token even though it's presented in a sheet.)

- [ ] **Step 2: Commit (LOCAL)**

```bash
git add whatsub-mobile/Corpus/CorpusView.swift
git commit -m "feat(corpus): 单词卡测验 entry button → QuizView sheet"
```

---

## Task 6: Integration — push, CI, merge, TestFlight

- [ ] **Step 1: Push the branch → CI (first real compile + unit tests)**

```bash
git push -u origin feat/ios-corpus-quiz
```
Watch the CI run (`gh run watch <id> --exit-status`). Expected: green (compiles + `QuizLogicTests`/`QuizProgressStoreTests`/`QuizViewModelTests` pass). If red, fix the compile/test error and re-push.

- [ ] **Step 2: Add a docs line + merge to main (triggers TestFlight)**

Add to `CLAUDE.md` Status line: a clause noting the 语料库 单词卡测验 (flashcard MC quiz, persistent local progress). Commit on the branch, then:
```bash
git checkout main
git merge --no-ff feat/ios-corpus-quiz -m "Merge corpus quiz (单词卡测验)"
git push origin main
```
This is the ONE TestFlight-triggering push. If the Archive fails with "maximum number of certificates", revoke an old cert at developer.apple.com → Certificates, then `gh run rerun <run-id>`.

- [ ] **Step 3: Manual e2e on TestFlight**

语料库 → 单词卡 → 公共/个人 → answer wrong (✗ shows, option disabled) → answer correct (✓ + reveal with meaning/usage) → 继续 → next; tap 看完整详情 → PhraseDetailView; force-quit + reopen → 已掌握 count retained; exhaust a small 个人 pool → 🎉 + 重置.

---

## Self-Review

**1. Spec coverage:**
- Client-side, no backend → Tasks 1-5 (only `browseCorpus`/`mineCorpus` reused). ✓
- Scope picker (公共/个人) → `QuizScope` + QuizView.scopePicker + VM.start. ✓
- 4-option MC, distractors from pool, shuffled → `QuizQuestionBuilder` (Task 1) + tests. ✓
- Wrong → ✗ + retry → VM.ruledOut + QuizView.optionButton disabled state. ✓
- Correct → inline reveal (meaning + usage + personal context) + 继续 + 看完整详情 → revealPanel. ✓
- Persistent local progress, write per completed phrase → `QuizProgressStore` (Task 2) + VM.answer→record. ✓
- Mastery = correctFirstTry≥2; 已掌握 X/共 Y + streak → QuizProgress.isMastered, header. ✓
- Weighted selection (fresh→learning→mastered) → `QuizSelection` (Task 1) + tests. ✓
- All mastered → 🎉 + reset → VM.advance allMastered + reset(); allMasteredBody. ✓
- Entry: 语料库 tab top → Task 5. ✓
- Edge: <4 insufficient; public-no-license error copy; duplicate meanings (Set-dedup distractors) → covered. ✓

**2. Placeholder scan:** No TBD/TODO/"handle errors". Every code step has full code. The only descriptive step is Task 6 Step 3 (manual e2e — inherent).

**3. Type consistency:**
- `QuizScope.publicCorpus/.mine` — defined Task 1, used Task 3 (`start`) + Task 4 (`startScope`). ✓
- `QuizCard{phraseNormalized,phraseRaw,meaningZh,usageNote,contextSentence}` — Task 1; built via `from(_:)` Task 3; read in QuizView. ✓
- `QuizProgress{seen,correctFirstTry,wrong,lastSeenAt}.isMastered` — Task 1; used by store (Task 2) + VM. ✓
- `QuizProgressStore(fileURL:)` + `record/progress/snapshot/masteredCount/reset` — Task 2; called by VM (Task 3) + tests. ✓
- `QuizQuestion{card,options,correct}` — Task 1; produced by VM, read by QuizView. ✓
- `QuizSelection.next(pool:progress:exclude:rng:)` + `bucket(_:)`, `QuizQuestionBuilder.build(card:pool:rng:)` — Task 1; called by VM.advance. ✓
- `QuizViewModel.Phase` cases (pickScope/loading/quizzing/insufficient/allMastered/error) — Task 3; switched in QuizView (Task 4) — all 6 covered. ✓
- `BrowsePhrase`/`MineItem` field names (`phraseNormalized`,`phraseRaw`,`meaningZh`,`usageNote`,`contextSentence`) — match DTOs.swift. ✓

No gaps found.
