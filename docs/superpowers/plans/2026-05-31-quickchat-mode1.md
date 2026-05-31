# QuickChat Mode ① 「快速对话 / 短语闯关」 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first "production"-side practice mode — a 60-90 s LLM dialogue that forces the user to *speak* 3 phrases drawn from their personal corpus, with per-turn verdict, real-time checklist, stuck-card review, and persistent production-mastery state.

**Architecture:** A new feature folder `whatsub-mobile/Practice/QuickChat/` with pure helpers (selector, prompt builder, verdict/sentence streaming scanners, store) layered under a single `QuickChatViewModel` FSM. Conversation streams over an extended `ChatCompletionsClient.stream(_:)` (the existing non-streaming `chat(_:)` is left untouched for import/CollectSheet). TTS reuses an upgraded `Quiz/Speaker.swift` parameterized by locale + rate (v1 is en-US-only; bilingual routing deferred to v1.1 per spec §6.3 + spike result). Mic + on-device SFSpeechRecognizer follow `Practice/ShadowSheet.swift` line-for-line. Entry sits in `CorpusView` header beside the existing 单词卡 button. Zero backend changes.

**Tech Stack:** Swift 5.10 · SwiftUI iOS 16+ · `AsyncThrowingStream` for SSE · `AVAudioRecorder` + `SFSpeechRecognizer(en-US, on-device)` · `AVSpeechSynthesizer` · `XCTest`.

**Spec:** `docs/superpowers/specs/2026-05-31-ai-voice-practice-corpus.md` (含 §0.1 spike 结果). **Spike transcript:** `docs/superpowers/specs/2026-05-31-spike-transcript.md`.

**Hard constraints from spec / spike:**
- Verdict sentinel = literal `<<<VERDICT>>>` and `<<<END>>>` (NOT ```json fence).
- `attempted` semantics = **this turn only**; UI checklist must be backed by a client-side `Set<String>` (the LLM defaults to cumulative semantics — spike §0.1 finding (e)).
- Phrase selection: Tier (Tier1 → Tier2 → Tier3) is a **hard** ordering; same-`tags` overlap is a **soft** bonus.
- 5-turn hard cap; turn 5 must NOT break role to praise the user (spike finding (b)).
- v1 TTS is **en-US only**; no markdown/bilingual handling needed.
- No backend calls beyond existing corpus reads.
- UI text MUST NOT contain `AI`/`ChatGPT`/`OpenAI`/`GPT` (App Store compliance, §9.7). Use 「对话陪练」「开口练」.

---

## File Map (decomposition)

**NEW under `whatsub-mobile/Practice/QuickChat/`:**

| File | Responsibility |
|---|---|
| `QuickChatModels.swift` | Value types: `ProductionProgress`, `SessionPhrase`, `ChatTurn`, `PhraseVerdict`, `TurnVerdict`, `SessionResult` |
| `ProductionProgressStore.swift` | File-backed `[phraseNormalized: ProductionProgress]` in `Documents/production_progress.json`. Mirrors `Quiz/QuizProgressStore.swift`. |
| `PhraseSelector.swift` | Pure: tier-then-tag selection from `[MineItem]` + recognition + production stores. |
| `QuickChatPrompts.swift` | Pure: builds system prompt string from `[SessionPhrase]` + optional suggested tag. |
| `VerdictParser.swift` | Pure streaming scanner: consumes assistant chunks, emits `(dialogText, verdictJSON?)` by tracking `<<<VERDICT>>>` / `<<<END>>>` sentinels. |
| `SentenceChunker.swift` | Pure streaming scanner: consumes dialog text chunks, emits complete sentences split on `.` `?` `!` or newline (for TTS feeding). |
| `ConversationEngine.swift` | Orchestrates `ChatCompletionsClient.stream` + `VerdictParser` + `SentenceChunker`; presents `AsyncThrowingStream<EngineEvent, Error>` to the view model. |
| `QuickChatViewModel.swift` | `@MainActor` FSM (`idle | recording | thinking | speaking | paused | summarizing | done`), session-local `Set<String>` of correct phrases, ChatTurn list, mic/ASR/TTS coordination, scenePhase + AVAudioSession interruption handling, production progress write-on-exit. |
| `QuickChatView.swift` | Root sheet UI: header checklist (3 chips), record/typing bar, transcript ScrollView, stuck-card popover, summary view, compliance gate. |
| `QuickChatStuckCardView.swift` | Per-phrase popup: `contextSentence` + `meaningZh` + `usageNote` (+ optional ▶ YouTube if `source.kind == "youtube"`). |
| `QuickChatSummaryView.swift` | End-of-session card: "用对 X/3" + per-phrase status + 再来一局 / 复习 / 关闭 buttons. |
| `QuickChatComplianceGate.swift` | First-launch one-time modal (UserDefaults flag `quickchat.compliance.acked.v1`). |
| `ReportMessageSheet.swift` | Long-press AI bubble → mailto: report to admin email (v1: mailto only, no backend). |

**MODIFY:**

| File | Change |
|---|---|
| `whatsub-mobile/LLM/ChatCompletionsClient.swift` | ADD `func stream(_:) -> AsyncThrowingStream<String, Error>` (existing `chat(_:)` untouched). |
| `whatsub-mobile/Quiz/Speaker.swift` | ADD `speak(_ text:, locale:, rate:)` overload; existing `speak(_:)` becomes a thin caller. |
| `whatsub-mobile/Corpus/CorpusView.swift` | Add 「对话陪练」 entry button in header beside 「单词卡」, gated on `mine.count >= 3`. |
| `project.yml` | Broaden mic + speech-recognition permission descriptions to mention 短语对话陪练. |

**NEW under `whatsub-mobileTests/`:**

| Test file | Coverage |
|---|---|
| `ProductionProgressStoreTests.swift` | Roundtrip, mastery threshold, expiry logic, missing/corrupt file. |
| `PhraseSelectorTests.swift` | Tier ordering, tag bucketing, cold start, fallback. |
| `VerdictParserTests.swift` | Single chunk, split across chunks, missing block, malformed JSON, multi-occurrence safety. |
| `SentenceChunkerTests.swift` | Sentence split across chunks, no-terminator-yet buffer, final-flush. |
| `QuickChatPromptsTests.swift` | Prompt contains all 3 phrases + scenario hint + verdict format + role-break guard. |
| `ChatCompletionsClientStreamTests.swift` | SSE line parsing (stub `URLProtocol` to emit canned `data:` lines). |
| `QuickChatViewModelTests.swift` | FSM transitions, session-Set tally, end-of-session write to store, mid-session exit safety. |

---

## Task Order & Dependencies

```
1. Models + store              (foundation, no deps)
   └─ 2. PhraseSelector         (depends on 1)
   └─ 3. QuickChatPrompts       (depends on 1)
4. VerdictParser                (no deps; pure stream scanner)
5. SentenceChunker              (no deps; pure stream scanner)
6. ChatCompletionsClient.stream (no deps; adds new func)
7. ConversationEngine           (depends on 1,3,4,5,6)
8. Speaker upgrade              (no deps; modifies existing)
9. QuickChatViewModel           (depends on 1,2,7,8 + mic/ASR like ShadowSheet)
10. UI shell: QuickChatView + chips + summary + stuck card + compliance gate + report sheet
                                (depends on 9)
11. Entry button in CorpusView  (depends on 10)
12. project.yml permission copy + ASC compliance audit checklist
                                (deployment-time concern; depends on 11)
13. Manual TestFlight smoke test path
```

Each task below is self-contained: open the named files, follow the steps, run the named tests, commit.

---

### Task 1: Models — `QuickChatModels.swift` + production-progress shape

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/QuickChatModels.swift`

- [ ] **Step 1: Create the file with all value types**

```swift
// whatsub-mobile/Practice/QuickChat/QuickChatModels.swift
import Foundation

/// Per-phrase production-mastery state. Mirrors QuizProgress in shape and
/// persistence pattern, but tracks "spoke it correctly in a dialogue" instead
/// of "picked the right Chinese meaning on a quiz card".
struct ProductionProgress: Codable, Equatable {
    var phraseNormalized: String
    var usedCorrectCount: Int = 0   // cumulative correct uses across sessions
    var attemptCount: Int = 0       // cumulative attempts (including wrong)
    var lastErrorNote: String? = nil
    var lastPracticedAt: Double = 0 // epoch seconds
    var masteredAt: Double? = nil   // set when usedCorrectCount first crosses threshold

    /// Spec §5: mastery threshold = 2 distinct correct uses (across sessions).
    static let masteryThreshold = 2
    /// Spec §5: spaced-repetition window. Mastered phrases reenter the pool
    /// after this many seconds idle.
    static let spacedRepetitionWindow: TimeInterval = 7 * 24 * 3600
}

/// One phrase the selector picked for this session. Carries the original
/// MineItem fields the view + prompt need (no need to keep the full MineItem).
struct SessionPhrase: Equatable, Identifiable {
    let phraseNormalized: String
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let contextSentence: String
    let sourceKind: String         // youtube | webpage | pdf | curator
    let sourceURL: String
    let sourceTimestampSec: Double?
    let tags: [String]
    var id: String { phraseNormalized }
}

/// One verdict entry for one phrase in one assistant turn.
struct PhraseVerdict: Codable, Equatable {
    let phrase: String         // phraseRaw — matches what's in the prompt
    let attempted: Bool
    let correct: Bool
    let note: String           // Chinese correction or empty
}

/// The JSON block between <<<VERDICT>>> ... <<<END>>>.
struct TurnVerdict: Codable, Equatable {
    let verdicts: [PhraseVerdict]
}

/// One round of dialogue (one user turn + one assistant reply).
struct ChatTurn: Identifiable, Equatable {
    let id = UUID()
    let userText: String           // empty for the opening assistant-only turn
    var assistantText: String      // accumulates as chunks stream in
    var verdict: TurnVerdict?      // parsed from the sentinel block
    let timestamp: Date = Date()
}

/// End-of-session summary written to ProductionProgressStore.
struct SessionResult {
    let phrases: [SessionPhrase]
    let correctlyUsed: Set<String>     // phraseNormalized
    let perPhraseErrorNotes: [String: String]  // phraseNormalized → most recent note
    let turnCount: Int
}
```

- [ ] **Step 2: Compile-check via project regeneration**

If on macOS:
```bash
xcodegen generate && xcodebuild -scheme whatsub-mobile -destination 'generic/platform=iOS Simulator' -configuration Debug build -quiet
```

If on Windows: push to a branch and rely on CI (`ci.yml`) for the build. Expected: green.

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/QuickChatModels.swift
git commit -m "feat(quickchat): models — ProductionProgress, SessionPhrase, ChatTurn, verdicts"
```

---

### Task 2: `ProductionProgressStore.swift` (TDD)

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/ProductionProgressStore.swift`
- Test: `whatsub-mobileTests/ProductionProgressStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// whatsub-mobileTests/ProductionProgressStoreTests.swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/ProductionProgressStoreTests
```
Expected: FAIL — `ProductionProgressStore` undefined.

- [ ] **Step 3: Implement the store**

```swift
// whatsub-mobile/Practice/QuickChat/ProductionProgressStore.swift
import Foundation

/// File-backed per-phrase production-mastery store. Mirror of
/// Quiz/QuizProgressStore.swift's "init loads from disk, mutation rewrites
/// atomically" pattern. Persists to Documents/production_progress.json by
/// default. Survives app kills. Local-only; no cloud sync in v1 (spec §3.2).
final class ProductionProgressStore {
    private let fileURL: URL
    private var phrases: [String: ProductionProgress]

    init(fileURL: URL = ProductionProgressStore.defaultURL) {
        self.fileURL = fileURL
        self.phrases = ProductionProgressStore.loadFrom(fileURL)
    }

    static var defaultURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("production_progress.json")
    }

    func progress(for phrase: String) -> ProductionProgress? { phrases[phrase] }
    func snapshot() -> [String: ProductionProgress] { phrases }

    /// Record one correct use. `at` is epoch seconds (Date().timeIntervalSince1970).
    /// Crossing the mastery threshold sets `masteredAt` (only the first crossing).
    func recordCorrect(phrase: String, at: Double) {
        var p = phrases[phrase] ?? ProductionProgress(phraseNormalized: phrase)
        p.usedCorrectCount += 1
        p.attemptCount += 1
        p.lastPracticedAt = at
        if p.masteredAt == nil, p.usedCorrectCount >= ProductionProgress.masteryThreshold {
            p.masteredAt = at
        }
        phrases[phrase] = p
        save()
    }

    /// Record one wrong attempt (the LLM said `attempted: true, correct: false`)
    /// or any tracked error. `note` becomes `lastErrorNote` for review.
    func recordWrong(phrase: String, note: String, at: Double) {
        var p = phrases[phrase] ?? ProductionProgress(phraseNormalized: phrase)
        p.attemptCount += 1
        p.lastErrorNote = note
        p.lastPracticedAt = at
        phrases[phrase] = p
        save()
    }

    /// True iff this phrase was mastered and the spaced-repetition window has
    /// elapsed since lastPracticedAt — so it should reenter the candidate pool.
    func isDueForRepetition(phrase: String, now: Double) -> Bool {
        guard let p = phrases[phrase], p.masteredAt != nil else { return false }
        return (now - p.lastPracticedAt) > ProductionProgress.spacedRepetitionWindow
    }

    // MARK: - Persistence (atomic, same pattern as QuizProgressStore)
    private struct FileShape: Codable { var version: Int; var phrases: [String: ProductionProgress] }

    private func save() {
        let shape = FileShape(version: 1, phrases: phrases)
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadFrom(_ url: URL) -> [String: ProductionProgress] {
        guard let data = try? Data(contentsOf: url),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data) else { return [:] }
        return shape.phrases
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/ProductionProgressStoreTests
```
Expected: 6/6 pass.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/ProductionProgressStore.swift whatsub-mobileTests/ProductionProgressStoreTests.swift
git commit -m "feat(quickchat): ProductionProgressStore (file-backed mastery; mirrors QuizProgressStore)"
```

---

### Task 3: `PhraseSelector.swift` (TDD) — Tier-hard + tag-soft

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/PhraseSelector.swift`
- Test: `whatsub-mobileTests/PhraseSelectorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// whatsub-mobileTests/PhraseSelectorTests.swift
import XCTest
@testable import whatsub_mobile

final class PhraseSelectorTests: XCTestCase {

    /// Helper: build a MineItem with just the fields the selector cares about.
    private func mine(_ key: String, tags: [String] = []) -> MineItem {
        MineItem(phraseNormalized: key, phraseRaw: key, meaningZh: nil,
                 usageNote: nil, contextSentence: "...",
                 source: CorpusSource(kind: "webpage", url: "", title: nil, timestampSec: nil),
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
        XCTAssertEqual(keys, ["a", "b", "c"], "spec §6.1 hard rule: Tier1 wins even with worse tag cohesion")
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
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/PhraseSelectorTests
```
Expected: FAIL — `PhraseSelector` undefined.

- [ ] **Step 3: Implement the selector**

```swift
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
        struct Cand { let item: MineItem; let tier: Tier }
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

        // 2. Tier 1 has a 3-same-tag bucket → use it directly.
        // 3. Tier 1 has 2+ items but no 3-bucket → {2 Tier 1 + 1 Tier 2/3} mix
        //    (spec §6.1 step 2: spaced-repetition rescue from Tier 2 gets a slot).
        // 4. Tier 1 has 0 or 1 items → cross-tag tier-order fill.
        //
        // (Caught by `testProducedButDueGoesIntoTier2` in CI — earlier "strict
        // tier order" variant never picked Tier 2's mastered+due rescue items.)
        let t1 = classified.filter { $0.tier == .t1 }
        let t2 = classified.filter { $0.tier == .t2 }
        let t3 = classified.filter { $0.tier == .t3 }
        // Rule 2
        if t1.count >= 3, let (tag, bucket) = largestTagBucket(in: t1), bucket.count >= 3 {
            return Pick(
                phrases: Array(bucket.prefix(3)).map { sessionPhrase(from: $0.item) },
                suggestedTag: tag
            )
        }
        // Rule 3
        if t1.count >= 2 {
            let pair = bestSameTagPair(in: t1) ?? Array(t1.prefix(2))
            let preferTags = Set(pair.flatMap { $0.item.tags })
            let third: Cand
            if let t2pick = pickPreferringTags(from: t2, prefer: preferTags) {
                third = t2pick
            } else if let t3pick = pickPreferringTags(from: t3, prefer: preferTags) {
                third = t3pick
            } else if t1.count >= 3 {
                let pickedKeys = Set(pair.map { $0.item.phraseNormalized })
                guard let extra = t1.first(where: { !pickedKeys.contains($0.item.phraseNormalized) }) else { return nil }
                third = extra
            } else {
                return nil
            }
            let picked = pair + [third]
            return Pick(phrases: picked.map { sessionPhrase(from: $0.item) },
                        suggestedTag: dominantTag(of: picked.map { $0.item.tags }))
        }
        // Rule 4: t1.count is 0 or 1; cross-tag tier-order fill.
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
        return Pick(phrases: picked.map { sessionPhrase(from: $0.item) },
                    suggestedTag: dominantTag(of: picked.map { $0.item.tags }))
    }

    // ---- helpers ----

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

    /// Internal helper type repeated outside `pick(...)` for use in helpers above.
    private struct Cand { let item: MineItem; let tier: Tier }
}
```

> ⚠️ The nested `Cand` type appears both inside `pick(...)` and as a private helper — Swift won't let `largestTagBucket` reference the nested one. Hoist `Cand` to the enum scope by **moving the `Cand` declaration immediately under `enum PhraseSelector {`** and removing it from inside `pick(...)`. (This is the one trap in the file; if a Swift compile error mentions `Cand`, this is why.)

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/PhraseSelectorTests
```
Expected: 6/6 pass.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/PhraseSelector.swift whatsub-mobileTests/PhraseSelectorTests.swift
git commit -m "feat(quickchat): PhraseSelector — tier-hard, tag-soft (spec §6.1 v2 patch)"
```

---

### Task 4: `QuickChatPrompts.swift` (TDD)

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/QuickChatPrompts.swift`
- Test: `whatsub-mobileTests/QuickChatPromptsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// whatsub-mobileTests/QuickChatPromptsTests.swift
import XCTest
@testable import whatsub_mobile

final class QuickChatPromptsTests: XCTestCase {

    private func phrase(_ raw: String, mean: String?, usage: String?, tags: [String] = []) -> SessionPhrase {
        SessionPhrase(phraseNormalized: raw, phraseRaw: raw, meaningZh: mean,
                      usageNote: usage, contextSentence: "ctx",
                      sourceKind: "webpage", sourceURL: "", sourceTimestampSec: nil,
                      tags: tags)
    }

    func testPromptContainsAllPhrasesWithMeaning() {
        let p = QuickChatPrompts.systemPrompt(
            phrases: [phrase("sort it out", mean: "解决", usage: "口语")],
            suggestedTag: nil
        )
        XCTAssertTrue(p.contains("sort it out"))
        XCTAssertTrue(p.contains("解决"))
        XCTAssertTrue(p.contains("口语"))
    }

    func testPromptIncludesScenarioHintWhenTagProvided() {
        let p = QuickChatPrompts.systemPrompt(
            phrases: [phrase("a", mean: "x", usage: nil)],
            suggestedTag: "餐厅点餐"
        )
        XCTAssertTrue(p.contains("餐厅点餐"))
    }

    func testPromptAsksLLMToInventSceneWhenNoTag() {
        let p = QuickChatPrompts.systemPrompt(
            phrases: [phrase("a", mean: "x", usage: nil)],
            suggestedTag: nil
        )
        // Must ask the LLM to pick its own scenario.
        XCTAssertTrue(p.contains("自行") || p.contains("自己"))
    }

    func testPromptDeclaresVerdictSentinelFormat() {
        let p = QuickChatPrompts.systemPrompt(phrases: [phrase("a", mean: "x", usage: nil)],
                                              suggestedTag: nil)
        // Sentinel literals (NOT JSON fence).
        XCTAssertTrue(p.contains("<<<VERDICT>>>"))
        XCTAssertTrue(p.contains("<<<END>>>"))
    }

    func testPromptForbidsRoleBreakAndTurn5Praise() {
        let p = QuickChatPrompts.systemPrompt(phrases: [phrase("a", mean: "x", usage: nil)],
                                              suggestedTag: nil)
        // Spec §6.2 hardened guards (spike findings (b) + (e)).
        XCTAssertTrue(p.contains("始终留在角色") || p.contains("留在角色"))
        XCTAssertTrue(p.contains("第 5 轮") || p.contains("第5轮"))
        XCTAssertTrue(p.contains("本轮") || p.contains("仅本轮"))
    }

    func testPromptIncludesAllThreePhrasesInOrder() {
        let phrases = [
            phrase("bouncing off the walls", mean: "兴奋", usage: "口语"),
            phrase("sort it out", mean: "解决", usage: "口语；语序 sort it out"),
            phrase("fair enough", mean: "有道理", usage: "口语回应"),
        ]
        let p = QuickChatPrompts.systemPrompt(phrases: phrases, suggestedTag: nil)
        let idxA = p.range(of: "bouncing off the walls")!.lowerBound
        let idxB = p.range(of: "sort it out")!.lowerBound
        let idxC = p.range(of: "fair enough")!.lowerBound
        XCTAssertTrue(idxA < idxB && idxB < idxC, "phrase order is preserved")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/QuickChatPromptsTests
```
Expected: FAIL — `QuickChatPrompts` undefined.

- [ ] **Step 3: Implement the builder**

```swift
// whatsub-mobile/Practice/QuickChat/QuickChatPrompts.swift
import Foundation

/// Builds the QuickChat system prompt. Pure function. The wording here is the
/// product itself — every constraint is a spec §6.2 / §6.4 / spike-finding line:
///
/// • "始终留在角色" — spec §6.2 anti-coach guard.
/// • "第 5 轮…不评判用户表现" — spike finding (b): LLM breaks role on goodbye to praise the user.
/// • "仅本轮" verdict semantics — spike finding (e): LLM otherwise drifts into cumulative semantics.
/// • Sentinel literals `<<<VERDICT>>>` / `<<<END>>>` — spec §6.4 (not JSON fence).
/// • Spike-validated: deepseek-chat respects this prompt 5/5 turns.
enum QuickChatPrompts {

    static func systemPrompt(phrases: [SessionPhrase], suggestedTag: String?) -> String {
        let phraseLines = phrases.map { p -> String in
            let meaning = p.meaningZh ?? "(略)"
            let usage = p.usageNote ?? "(略)"
            return "- \"\(p.phraseRaw)\" — 意思：\(meaning)；用法：\(usage)"
        }.joined(separator: "\n")

        let scenarioLine: String
        if let tag = suggestedTag, !tag.isEmpty {
            scenarioLine = "建议情景：\(tag)。请自然起一个能容纳这些短语的小情景对话。"
        } else {
            scenarioLine = "请自行设一个能自然容纳这些短语的日常情景。"
        }

        // Sentinel format MUST be literal — the parser scans for these exact strings.
        let verdictTemplate = phrases.map { p in
            "  {\"phrase\":\"\(p.phraseRaw)\",\"attempted\":<bool>,\"correct\":<bool>,\"note\":\"<纠正或空>\"}"
        }.joined(separator: ",\n")

        return """
        你是一个英语口语对话练习陪练。本局用户要练以下英文短语：
        \(phraseLines)

        \(scenarioLine)

        行为约束（硬性）：
        1. 起一个简短情景，自然引导用户说出每个目标短语；不要直接告诉用户答案。
        2. 始终留在角色里。禁止跳出说"我们来练 XXX 吧"或"这个短语意思是…"——纠正必须以角色内自然反应给出。
        3. 用户用错时温柔纠正；可中文或英文，但要简短自然，不要打断节奏。
        4. 节奏 3–5 轮内收敛。
        5. 第 5 轮收尾仍以角色身份给出告别词；不要评判用户表现、不要夸奖"你今天用对了几个短语"、不要做 lesson summary——评判由客户端 UI 在局末根据 verdict 数据呈现。

        输出协议（每轮必须遵守）：
        你每次回复的格式必须是：
        <assistant 自然语言对话正文（英文主体）>
        <<<VERDICT>>>
        {"verdicts":[
        \(verdictTemplate)
        ]}
        <<<END>>>

        verdicts 必须包含全部 \(phrases.count) 个短语。
        - `attempted` 指**仅本轮**用户消息里有没有尝试使用该短语；不要把之前轮次里的成功带进来。
        - `correct` 指尝试且语法/搭配/语境正确。
        - `note` 用中文写一句简短纠正或留空。
        """
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/QuickChatPromptsTests
```
Expected: 6/6 pass.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/QuickChatPrompts.swift whatsub-mobileTests/QuickChatPromptsTests.swift
git commit -m "feat(quickchat): QuickChatPrompts — sentinel verdict + role/turn-5/本轮 guards (spike-validated)"
```

---

### Task 5: `VerdictParser.swift` (TDD) — streaming sentinel scanner

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/VerdictParser.swift`
- Test: `whatsub-mobileTests/VerdictParserTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// whatsub-mobileTests/VerdictParserTests.swift
import XCTest
@testable import whatsub_mobile

final class VerdictParserTests: XCTestCase {

    func testSingleChunkSplitsDialogAndVerdict() {
        var p = VerdictParser()
        let out = p.feed("Hello there!\n<<<VERDICT>>>\n{\"verdicts\":[]}\n<<<END>>>\n")
        XCTAssertEqual(out.dialogChunk, "Hello there!\n")
        XCTAssertNotNil(out.completedVerdict)
        XCTAssertEqual(out.completedVerdict?.verdicts.count, 0)
    }

    func testSentinelSplitAcrossChunks() {
        var p = VerdictParser()
        let a = p.feed("Hello there! <<<VER")
        XCTAssertEqual(a.dialogChunk, "Hello there! ")     // hold back the partial sentinel
        XCTAssertNil(a.completedVerdict)
        let b = p.feed("DICT>>>\n{\"verdicts\":[")
        XCTAssertEqual(b.dialogChunk, "", "after sentinel: nothing more goes to dialog")
        XCTAssertNil(b.completedVerdict)
        let c = p.feed("]}\n<<<END>>>")
        XCTAssertEqual(c.dialogChunk, "")
        XCTAssertNotNil(c.completedVerdict)
    }

    func testDialogOnlyWhenNoSentinelEver() {
        var p = VerdictParser()
        let out = p.feed("just talking, no verdict here.")
        XCTAssertEqual(out.dialogChunk, "just talking, no verdict here.")
        XCTAssertNil(out.completedVerdict)
        // Caller flushes at end-of-stream:
        let final = p.finish()
        XCTAssertNil(final.completedVerdict, "missing verdict = nil, not an error")
    }

    func testMalformedVerdictJSONReturnsNilButDoesntCrash() {
        var p = VerdictParser()
        let out = p.feed("hi\n<<<VERDICT>>>\nthis is not json\n<<<END>>>")
        XCTAssertEqual(out.dialogChunk, "hi\n")
        XCTAssertNil(out.completedVerdict, "bad JSON behaves like missing verdict")
    }

    func testCharBeforePartialSentinelStillFlushed() {
        var p = VerdictParser()
        // The '<' itself isn't yet a confirmed sentinel start; everything before
        // it must still flush to dialog so TTS doesn't lag.
        let out = p.feed("ok then.<")
        XCTAssertEqual(out.dialogChunk, "ok then.")
        let next = p.feed("<<VERDICT>>>")
        // Confirmed — the held '<' chars rolled into the sentinel match. Nothing
        // new for dialog.
        XCTAssertEqual(next.dialogChunk, "")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/VerdictParserTests
```
Expected: FAIL — `VerdictParser` undefined.

- [ ] **Step 3: Implement the parser**

```swift
// whatsub-mobile/Practice/QuickChat/VerdictParser.swift
import Foundation

/// Streaming sentinel scanner. Consumes assistant chunks one at a time and
/// returns: (a) the portion safe to forward as dialog (and feed TTS), and
/// (b) — once `<<<VERDICT>>>...<<<END>>>` has been seen in full — the parsed
/// TurnVerdict.
///
/// Why streaming: spec §6.2 wants TTS to start playing the first sentence
/// before the verdict block arrives, so we can't wait for the full response.
///
/// Holdback: we keep up to `(startSentinel.count - 1)` trailing chars in a
/// buffer in case the sentinel is straddling a chunk boundary. Anything older
/// is safe to flush — at worst the sentinel can't have started any later.
struct VerdictParser {
    struct Output {
        let dialogChunk: String                 // safe-to-display text from THIS feed
        let completedVerdict: TurnVerdict?      // non-nil exactly once per turn (or never)
    }

    private static let startSentinel = "<<<VERDICT>>>"
    private static let endSentinel   = "<<<END>>>"

    private enum Phase { case dialog, verdict, done }
    private var phase: Phase = .dialog
    private var dialogBuffer = ""           // potential-sentinel-prefix carryover
    private var verdictBuffer = ""

    /// Feed a chunk; get back what's safe to render + maybe a finished verdict.
    mutating func feed(_ chunk: String) -> Output {
        switch phase {
        case .done:
            return Output(dialogChunk: "", completedVerdict: nil)
        case .verdict:
            verdictBuffer += chunk
            if let endRange = verdictBuffer.range(of: Self.endSentinel) {
                let jsonText = String(verdictBuffer[..<endRange.lowerBound])
                phase = .done
                let parsed = parseVerdict(jsonText)
                return Output(dialogChunk: "", completedVerdict: parsed)
            }
            return Output(dialogChunk: "", completedVerdict: nil)
        case .dialog:
            dialogBuffer += chunk
            // If the start sentinel is fully present, split there.
            if let startRange = dialogBuffer.range(of: Self.startSentinel) {
                let before = String(dialogBuffer[..<startRange.lowerBound])
                let after = String(dialogBuffer[startRange.upperBound...])
                dialogBuffer = ""
                phase = .verdict
                // Recurse to handle the remainder, which may already contain end sentinel.
                let tail = self.feed(after)
                return Output(
                    dialogChunk: before + tail.dialogChunk,    // tail.dialogChunk is "" here
                    completedVerdict: tail.completedVerdict
                )
            }
            // No full sentinel yet — hold back ONLY the longest suffix of the
            // buffer that is a prefix of the start sentinel. Naive "hold back
            // sentinelLength-1 chars" stalls dialog flushing unnecessarily
            // (caught in Task 5 review — `testCharBeforePartialSentinelStillFlushed`
            // requires this smarter approach).
            let holdback = Self.longestSentinelPrefixSuffix(of: dialogBuffer)
            let safeCount = dialogBuffer.count - holdback
            let safeEnd = dialogBuffer.index(dialogBuffer.startIndex, offsetBy: safeCount)
            let safe = String(dialogBuffer[..<safeEnd])
            dialogBuffer = String(dialogBuffer[safeEnd...])
            return Output(dialogChunk: safe, completedVerdict: nil)
        }
    }

    /// Length of the longest suffix of `buffer` that is also a prefix of `startSentinel`.
    /// Walks from min(buffer.count, sentinelLen-1) down to 1.
    private static func longestSentinelPrefixSuffix(of buffer: String) -> Int {
        let maxN = min(buffer.count, startSentinel.count - 1)
        for n in stride(from: maxN, through: 1, by: -1) {
            let suffix = String(buffer.suffix(n))
            if startSentinel.hasPrefix(suffix) { return n }
        }
        return 0
    }

    /// Flush at end-of-stream. If we were still in `.dialog` and the partial
    /// buffer didn't turn into a sentinel, it's plain dialog after all.
    mutating func finish() -> Output {
        switch phase {
        case .dialog:
            let leftover = dialogBuffer
            dialogBuffer = ""
            phase = .done
            return Output(dialogChunk: leftover, completedVerdict: nil)
        case .verdict, .done:
            // No closing sentinel = malformed. Per spec §6.4: equivalent to "no verdict", not an error.
            phase = .done
            return Output(dialogChunk: "", completedVerdict: nil)
        }
    }

    // ---- parsing ----
    private func parseVerdict(_ jsonText: String) -> TurnVerdict? {
        guard let data = jsonText.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TurnVerdict.self, from: data)
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/VerdictParserTests
```
Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/VerdictParser.swift whatsub-mobileTests/VerdictParserTests.swift
git commit -m "feat(quickchat): VerdictParser — streaming <<<VERDICT>>>/<<<END>>> sentinel scanner"
```

---

### Task 6: `SentenceChunker.swift` (TDD)

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/SentenceChunker.swift`
- Test: `whatsub-mobileTests/SentenceChunkerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// whatsub-mobileTests/SentenceChunkerTests.swift
import XCTest
@testable import whatsub_mobile

final class SentenceChunkerTests: XCTestCase {

    func testEmitsOnPeriodOrQuestionOrExclamation() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hello world."), ["Hello world."])
        XCTAssertEqual(c.feed("Are you ok?"), ["Are you ok?"])
        XCTAssertEqual(c.feed("Stop!"), ["Stop!"])
    }

    func testWaitsUntilTerminator() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hello "), [])
        XCTAssertEqual(c.feed("world"), [])
        XCTAssertEqual(c.feed("."), ["Hello world."])
    }

    func testMultipleSentencesInOneChunk() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hi. How are you? Fine."),
                       ["Hi.", "How are you?", "Fine."])
    }

    func testNewlineActsAsTerminator() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Line one\nLine two\n"), ["Line one", "Line two"])
    }

    func testFlushReturnsTrailingPartial() {
        var c = SentenceChunker()
        _ = c.feed("Hello ")
        XCTAssertEqual(c.flush(), ["Hello"])  // trimmed
        XCTAssertEqual(c.flush(), [])         // already flushed
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/SentenceChunkerTests
```
Expected: FAIL — `SentenceChunker` undefined.

- [ ] **Step 3: Implement the chunker**

```swift
// whatsub-mobile/Practice/QuickChat/SentenceChunker.swift
import Foundation

/// Splits a stream of text chunks into complete sentences, useful for feeding
/// AVSpeechSynthesizer one sentence at a time so TTS starts before the LLM
/// has finished. Spec §6.3 "流式 TTS 切句喂".
///
/// Terminators: '.', '?', '!', or any newline ('\n', '\r'). Whitespace-only
/// fragments are dropped. flush() returns whatever's still buffered.
struct SentenceChunker {
    private var buffer = ""
    private static let terminators: Set<Character> = [".", "?", "!", "\n", "\r"]

    mutating func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var out: [String] = []
        var current = ""
        for ch in buffer {
            if Self.terminators.contains(ch) {
                let isNewline = ch == "\n" || ch == "\r"
                let sentence: String
                if isNewline {
                    sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    sentence = (current + String(ch)).trimmingCharacters(in: .whitespaces)
                }
                if !sentence.isEmpty { out.append(sentence) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        buffer = current   // keep the partial sentence for next call
        return out
    }

    mutating func flush() -> [String] {
        let leftover = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return leftover.isEmpty ? [] : [leftover]
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/SentenceChunkerTests
```
Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/SentenceChunker.swift whatsub-mobileTests/SentenceChunkerTests.swift
git commit -m "feat(quickchat): SentenceChunker — sentence-boundary stream splitter for TTS"
```

---

### Task 7: Extend `ChatCompletionsClient.swift` with `stream(_:)` (TDD)

**Files:**
- Modify: `whatsub-mobile/LLM/ChatCompletionsClient.swift` (add func, don't change existing)
- Test: `whatsub-mobileTests/ChatCompletionsClientStreamTests.swift`

The stream uses `URLSession.bytes(for:)` + `.lines` to read line-delimited SSE. We test the SSE-line parsing by registering a `URLProtocol` mock that emits canned `data:` lines.

- [ ] **Step 1: Write the failing test**

```swift
// whatsub-mobileTests/ChatCompletionsClientStreamTests.swift
import XCTest
@testable import whatsub_mobile

/// Mocks any URLRequest, returns a fixed SSE-encoded body. Registered once
/// per test via URLSessionConfiguration.protocolClasses.
final class StubSSEProtocol: URLProtocol {
    static var responseBody: String = ""
    static var status: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ChatCompletionsClientStreamTests: XCTestCase {
    private func sse(_ lines: [String]) -> String {
        // Real DeepSeek format: each event is `data: {...}\n\n`.
        lines.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
    }

    func testStreamYieldsContentChunksInOrder() async throws {
        StubSSEProtocol.status = 200
        StubSSEProtocol.responseBody = sse([
            #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"{"choices":[{"delta":{"content":" there"}}]}"#,
            #"{"choices":[{"delta":{"content":"!"}}]}"#,
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubSSEProtocol.self]
        let session = URLSession(configuration: config)
        let client = ChatCompletionsClient(
            settings: LlmSettings(baseUrl: "https://stub.test/v1", apiKey: "k", model: "m"),
            session: session
        )
        var got: [String] = []
        for try await chunk in client.stream([ChatMessage(role: "user", content: "hi")]) {
            got.append(chunk)
        }
        XCTAssertEqual(got, ["Hello", " there", "!"])
    }

    func testStreamFinishesOnDONESentinel() async throws {
        StubSSEProtocol.status = 200
        StubSSEProtocol.responseBody = "data: \(#"{"choices":[{"delta":{"content":"x"}}]}"#)\n\ndata: [DONE]\n\ndata: \(#"{"choices":[{"delta":{"content":"AFTER_DONE"}}]}"#)\n\n"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubSSEProtocol.self]
        let session = URLSession(configuration: config)
        let client = ChatCompletionsClient(
            settings: LlmSettings(baseUrl: "https://stub.test/v1", apiKey: "k", model: "m"),
            session: session
        )
        var got: [String] = []
        for try await chunk in client.stream([ChatMessage(role: "user", content: "hi")]) {
            got.append(chunk)
        }
        XCTAssertEqual(got, ["x"], "anything after [DONE] is discarded")
    }

    func testStreamThrowsOnNon2xxStatus() async {
        StubSSEProtocol.status = 401
        StubSSEProtocol.responseBody = "data: unauthorized\n\n"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubSSEProtocol.self]
        let session = URLSession(configuration: config)
        let client = ChatCompletionsClient(
            settings: LlmSettings(baseUrl: "https://stub.test/v1", apiKey: "k", model: "m"),
            session: session
        )
        do {
            for try await _ in client.stream([ChatMessage(role: "user", content: "hi")]) {}
            XCTFail("expected throw")
        } catch {
            // pass — any error type is fine; we just want it to surface
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/ChatCompletionsClientStreamTests
```
Expected: FAIL — `stream(_:)` and `init(settings:session:)` undefined.

- [ ] **Step 3: Add the stream branch + injectable session**

Edit `whatsub-mobile/LLM/ChatCompletionsClient.swift` — replace the existing `struct ChatCompletionsClient { let settings: LlmSettings ... }` block with the extended version below. The existing `chat(_:)` method is preserved verbatim; only the struct header and a new `stream(_:)` are added.

```swift
// whatsub-mobile/LLM/ChatCompletionsClient.swift  (full replacement)
import Foundation

struct ChatMessage { let role: String; let content: String }

/// Minimal /chat/completions client. The non-streaming `chat(_:)` is used by
/// import + CollectSheet (one shot, return the full content). The streaming
/// `stream(_:)` is used by QuickChat for low-latency turn-by-turn dialogue
/// (TTS starts on the first chunk).
///
/// `session` is injectable so tests can stub the URLProtocol.
struct ChatCompletionsClient {
    let settings: LlmSettings
    let session: URLSession

    init(settings: LlmSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    // MARK: - non-streaming (unchanged caller surface)

    func chat(_ messages: [ChatMessage]) async throws -> String {
        guard settings.isConfigured, let url = URL(string: "\(settings.baseUrl)/chat/completions") else {
            throw LlmError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "model": settings.model,
            "stream": false,
            "temperature": 0.3,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw LlmError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw LlmError.network("no http") }
        guard (200..<300).contains(http.statusCode) else {
            throw LlmError.api(http.statusCode, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LlmError.badResponse
        }
        return content
    }

    // MARK: - streaming (new, for QuickChat)

    /// Yields each `delta.content` chunk as it arrives. Terminates on the
    /// `data: [DONE]` SSE sentinel. Network/parse errors propagate via the
    /// stream's throwing finish.
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard settings.isConfigured,
                          let url = URL(string: "\(settings.baseUrl)/chat/completions") else {
                        throw LlmError.notConfigured
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 120
                    let body: [String: Any] = [
                        "model": settings.model,
                        "stream": true,
                        "temperature": 0.3,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        throw LlmError.network("no http")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Drain a bit of body for the error context.
                        var sample = ""
                        for try await line in bytes.lines {
                            sample += line
                            if sample.count >= 200 { break }
                        }
                        throw LlmError.api(http.statusCode, sample)
                    }

                    for try await line in bytes.lines {
                        // SSE: each event is a `data: ...` line, plus blank line. We
                        // only care about the data lines; `bytes.lines` already gives
                        // them stripped of trailing newlines and skips empty lines.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            break
                        }
                        if let data = payload.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let chunk = delta["content"] as? String,
                           !chunk.isEmpty {
                            continuation.yield(chunk)
                        }
                        // Other lines (role-only first chunk, finish_reason without content, etc.) are no-ops.
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - errors (unchanged)

    enum LlmError: Error, LocalizedError {
        case notConfigured, network(String), api(Int, String), badResponse
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "请先在「我的 → LLM 设置」填入 API Key"
            case .network(let d): return "网络失败：\(d)"
            case .api(let c, _): return "LLM 接口错误（\(c)）"
            case .badResponse: return "LLM 返回格式异常"
            }
        }
    }
}
```

- [ ] **Step 4: Run all tests to verify pass + no regression**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/ChatCompletionsClientStreamTests
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/AnalysisEngineTests
```
Expected: stream tests 3/3 pass; AnalysisEngine tests still pass (non-streaming path unchanged).

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/LLM/ChatCompletionsClient.swift whatsub-mobileTests/ChatCompletionsClientStreamTests.swift
git commit -m "feat(llm): add ChatCompletionsClient.stream() for SSE streaming (QuickChat path)"
```

---

### Task 8: `ConversationEngine.swift`

This glues `ChatCompletionsClient.stream` + `VerdictParser` + `SentenceChunker` into one cohesive AsyncThrowingStream that the view model can drive.

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/ConversationEngine.swift`

There are no unit tests for the engine itself (it's wiring around already-tested pieces). The view-model tests in Task 10 cover its end-to-end behavior via injection.

- [ ] **Step 1: Implement**

```swift
// whatsub-mobile/Practice/QuickChat/ConversationEngine.swift
import Foundation

/// Drives one QuickChat session: holds the running message history, calls
/// ChatCompletionsClient.stream for each turn, splits the assistant response
/// into dialog (→ TTS-friendly sentence stream + UI text) and verdict (→ parsed
/// TurnVerdict). Pure orchestration around tested helpers — see VerdictParser,
/// SentenceChunker, ChatCompletionsClient.stream.
@MainActor
final class ConversationEngine {
    /// One event during a turn.
    enum Event {
        /// A complete sentence ready to send to TTS + append to UI.
        case sentence(String)
        /// Partial dialog text — accumulates into the assistant bubble. Caller
        /// may show it incrementally even before a sentence boundary.
        case dialogDelta(String)
        /// The verdict JSON has finished parsing. Fires at most once per turn,
        /// usually near the end of the stream.
        case verdict(TurnVerdict)
        /// Stream completed naturally. The full assistant text and (maybe) the
        /// verdict have already been emitted as separate events above.
        case finished
    }

    private let client: ChatCompletionsClient
    private(set) var messages: [ChatMessage]

    init(client: ChatCompletionsClient, systemPrompt: String) {
        self.client = client
        self.messages = [ChatMessage(role: "system", content: systemPrompt)]
    }

    /// Run one turn. `userInput` is "" for the opening turn (LLM opens scene).
    /// Yields events as they happen; throws on network/format errors.
    ///
    /// Spec §6.5.1: per-turn idle-chunk timeout. If 30 s pass between chunks
    /// we throw a `LlmError.network("idle-chunk timeout")` so the view model
    /// can surface it as "再说一次或换文字" instead of waiting forever.
    func runTurn(userInput: String) -> AsyncThrowingStream<Event, Error> {
        if !userInput.isEmpty {
            messages.append(ChatMessage(role: "user", content: userInput))
        }
        let stream = client.stream(messages)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = VerdictParser()
                var chunker = SentenceChunker()
                var fullAssistantText = ""   // including verdict block — we replay full into history
                var lastChunkAt = Date()
                let idleLimit: TimeInterval = 30
                // Watchdog: cancels the iterator if no chunk arrives for idleLimit.
                let watchdog = Task { [weak self] in
                    _ = self  // silence unused-self warning; we don't touch state from here
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if Date().timeIntervalSince(lastChunkAt) > idleLimit {
                            continuation.finish(throwing: ChatCompletionsClient.LlmError.network("idle-chunk timeout"))
                            return
                        }
                    }
                }
                defer { watchdog.cancel() }
                do {
                    for try await raw in stream {
                        lastChunkAt = Date()
                        fullAssistantText += raw
                        let out = parser.feed(raw)
                        if !out.dialogChunk.isEmpty {
                            continuation.yield(.dialogDelta(out.dialogChunk))
                            for sentence in chunker.feed(out.dialogChunk) {
                                continuation.yield(.sentence(sentence))
                            }
                        }
                        if let v = out.completedVerdict {
                            continuation.yield(.verdict(v))
                        }
                    }
                    // Stream done — drain any held buffers.
                    let tail = parser.finish()
                    if !tail.dialogChunk.isEmpty {
                        continuation.yield(.dialogDelta(tail.dialogChunk))
                        for sentence in chunker.feed(tail.dialogChunk) {
                            continuation.yield(.sentence(sentence))
                        }
                    }
                    for sentence in chunker.flush() {
                        continuation.yield(.sentence(sentence))
                    }
                    if let v = tail.completedVerdict {
                        continuation.yield(.verdict(v))
                    }
                    // Record the full assistant text (including verdict block) in
                    // history so the next turn's LLM sees its own previous output.
                    messages.append(ChatMessage(role: "assistant", content: fullAssistantText))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/ConversationEngine.swift
git commit -m "feat(quickchat): ConversationEngine — stream → (sentence, dialogDelta, verdict) events"
```

---

### Task 9: Upgrade `Quiz/Speaker.swift` with parameterized locale + rate

We extend Speaker so QuickChat can use `en-US` slightly faster, single-line, mixing-with-others, while existing call sites (`Speaker.speak(_:)` in `QuizView`) keep working unchanged.

**Files:**
- Modify: `whatsub-mobile/Quiz/Speaker.swift`

- [ ] **Step 1: Replace the file**

```swift
// whatsub-mobile/Quiz/Speaker.swift  (full replacement)
import AVFoundation

/// English / Chinese TTS using `AVSpeechSynthesizer`. Two entry points:
///
/// - `speak(_:)`            — Quiz word card; reads a short English phrase
///                            in a known female en-US voice (Samantha
///                            preferred). Behavior unchanged from v1.
/// - `speak(_:locale:rate:)` — QuickChat sentence-by-sentence streaming.
///                            Caller supplies locale (defaults en-US) and
///                            rate (defaults to AVDefault * 1.0). Queues
///                            utterances rather than stopping prior speech,
///                            so the LLM's first sentence keeps playing
///                            while the next streams in.
///
/// Spec §6.3 (v1 single-language en-US after spike result; bilingual routing
/// deferred to v1.1 per §12).
enum Speaker {
    private static let synth = AVSpeechSynthesizer()
    private static let femaleNames = [
        "Samantha", "Ava", "Allison", "Susan", "Nicky", "Joelle",
        "Karen", "Moira", "Tessa", "Serena", "Fiona", "Zoe",
    ]

    /// Quiz-card flow (unchanged contract): interrupts any in-flight speech.
    static func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        configureSessionIfNeeded()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synth.speak(makeUtterance(trimmed, locale: "en-US", rate: AVSpeechUtteranceDefaultSpeechRate * 0.95))
    }

    /// QuickChat streaming flow: queues utterances so sentence-by-sentence
    /// feeding plays back contiguously. Does NOT interrupt prior speech.
    static func enqueue(_ text: String, locale: String = "en-US",
                       rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        configureSessionIfNeeded()
        synth.speak(makeUtterance(trimmed, locale: locale, rate: rate))
    }

    /// Stop everything (called when QuickChat ends, user pauses, or the
    /// AVAudioSession is interrupted).
    static func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    // ---- internals ----

    private static func configureSessionIfNeeded() {
        // Audible even with the silent switch on, mixing with any background audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    private static func makeUtterance(_ text: String, locale: String, rate: Float) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        u.voice = pickVoice(locale: locale)
        return u
    }

    private static func pickVoice(locale: String) -> AVSpeechSynthesisVoice? {
        if locale.hasPrefix("en") {
            let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            for name in femaleNames {
                if let v = english.first(where: { $0.name == name && $0.language == "en-US" }) { return v }
            }
            for name in femaleNames {
                if let v = english.first(where: { $0.name == name }) { return v }
            }
        }
        return AVSpeechSynthesisVoice(language: locale)
    }
}
```

- [ ] **Step 2: Build + run existing Quiz tests to confirm no regression**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/QuizViewModelTests
```
Expected: pre-existing tests still pass (Speaker is fire-and-forget; not directly asserted, so this is a build smoke).

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Quiz/Speaker.swift
git commit -m "refactor(speaker): parameterize locale + rate; add enqueue() for QuickChat streaming"
```

---

### Task 10: `QuickChatViewModel.swift` (FSM + session tally + interrupt handling)

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/QuickChatViewModel.swift`
- Test: `whatsub-mobileTests/QuickChatViewModelTests.swift`

The view model is the largest single file but most of its logic is testable through the FSM transitions + the session-Set tally. We test those without touching real mic/TTS by injecting a closure-based `EngineDriver` seam.

- [ ] **Step 1: Write the failing test for FSM + session-Set + production write**

```swift
// whatsub-mobileTests/QuickChatViewModelTests.swift
import XCTest
@testable import whatsub_mobile

@MainActor
final class QuickChatViewModelTests: XCTestCase {

    private func phrase(_ raw: String) -> SessionPhrase {
        SessionPhrase(phraseNormalized: raw, phraseRaw: raw, meaningZh: nil,
                      usageNote: nil, contextSentence: "", sourceKind: "webpage",
                      sourceURL: "", sourceTimestampSec: nil, tags: [])
    }

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vmtest_\(UUID().uuidString).json")
    }

    func testInitialPhaseIsThinkingThenIdleAfterOpenTurn() async throws {
        let storeURL = tempStoreURL()
        let store = ProductionProgressStore(fileURL: storeURL)
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: [
                // Opening turn — assistant says "Hi.", no verdict yet.
                .init(events: [.dialogDelta("Hi."), .sentence("Hi."),
                               .verdict(TurnVerdict(verdicts: [
                                   .init(phrase: "a", attempted: false, correct: false, note: ""),
                                   .init(phrase: "b", attempted: false, correct: false, note: ""),
                                   .init(phrase: "c", attempted: false, correct: false, note: ""),
                               ])), .finished])
            ]),
            now: { 100 }
        )
        await vm.start()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.turns.count, 1)
        XCTAssertEqual(vm.turns[0].assistantText, "Hi.")
        XCTAssertTrue(vm.completedPhrases.isEmpty)
        try? FileManager.default.removeItem(at: storeURL)
    }

    func testCorrectVerdictAddsToSessionSetAndPlaysFeedback() async throws {
        let store = ProductionProgressStore(fileURL: tempStoreURL())
        let verdict = TurnVerdict(verdicts: [
            .init(phrase: "a", attempted: true, correct: true, note: ""),
            .init(phrase: "b", attempted: false, correct: false, note: ""),
            .init(phrase: "c", attempted: false, correct: false, note: ""),
        ])
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: [
                .init(events: [.finished]),                                  // opening
                .init(events: [.verdict(verdict), .finished]),               // user turn 1
            ]),
            now: { 100 }
        )
        await vm.start()
        await vm.submitUserInput("I'm a using it.")
        XCTAssertEqual(vm.completedPhrases, ["a"])
    }

    func testCumulativeDriftDoesNotDoubleCountInStore() async throws {
        // LLM mis-marks "a" correct in turn 2 even though user didn't use it.
        // The session-Set already contains "a" from turn 1, so the store should
        // record only ONE +1 for "a" (not two).
        let storeURL = tempStoreURL()
        let store = ProductionProgressStore(fileURL: storeURL)
        let correctA = TurnVerdict(verdicts: [
            .init(phrase: "a", attempted: true, correct: true, note: ""),
            .init(phrase: "b", attempted: false, correct: false, note: ""),
            .init(phrase: "c", attempted: false, correct: false, note: ""),
        ])
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: [
                .init(events: [.finished]),                          // opening
                .init(events: [.verdict(correctA), .finished]),      // turn 1
                .init(events: [.verdict(correctA), .finished]),      // turn 2 — same flag (drift)
            ]),
            now: { 100 }
        )
        await vm.start()
        await vm.submitUserInput("a a a")
        await vm.submitUserInput("xyz")
        XCTAssertEqual(vm.completedPhrases, ["a"])
        await vm.endSession()
        XCTAssertEqual(store.progress(for: "a")?.usedCorrectCount, 1,
                       "session-Set guarantees at most +1 per phrase per session")
        try? FileManager.default.removeItem(at: storeURL)
    }

    func testEndOnTurn5HardCap() async throws {
        let store = ProductionProgressStore(fileURL: tempStoreURL())
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: Array(repeating: .init(events: [.finished]), count: 6)),
            now: { 100 }
        )
        await vm.start()                          // turn 0 (opening)
        for _ in 1...4 { await vm.submitUserInput("x") }    // turns 1..4
        XCTAssertEqual(vm.phase, .idle, "still going at turn 4")
        await vm.submitUserInput("x")             // turn 5 — auto-end
        XCTAssertEqual(vm.phase, .done, "5-turn hard cap (spec §9 #4)")
    }

    func testExitMidSessionPersistsAccumulatedVerdicts() async throws {
        let storeURL = tempStoreURL()
        let store = ProductionProgressStore(fileURL: storeURL)
        let correctA = TurnVerdict(verdicts: [
            .init(phrase: "a", attempted: true, correct: true, note: ""),
            .init(phrase: "b", attempted: false, correct: false, note: ""),
            .init(phrase: "c", attempted: false, correct: false, note: ""),
        ])
        let vm = QuickChatViewModel(
            phrases: [phrase("a"), phrase("b"), phrase("c")],
            suggestedTag: nil,
            progressStore: store,
            engineDriver: .stub(turns: [
                .init(events: [.finished]),
                .init(events: [.verdict(correctA), .finished]),
            ]),
            now: { 100 }
        )
        await vm.start()
        await vm.submitUserInput("hi")
        // User taps "关闭" — simulate via endSession before normal completion.
        await vm.endSession()
        XCTAssertEqual(store.progress(for: "a")?.usedCorrectCount, 1,
                       "spec §6.5.1: mid-session exit must not lose verdicts")
        try? FileManager.default.removeItem(at: storeURL)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/QuickChatViewModelTests
```
Expected: FAIL — `QuickChatViewModel` undefined.

- [ ] **Step 3: Implement the view model**

```swift
// whatsub-mobile/Practice/QuickChat/QuickChatViewModel.swift
import Foundation
import SwiftUI
import AVFoundation
import Speech
import UIKit

/// Testable seam: production wraps ConversationEngine; tests inject canned turns.
struct EngineDriver {
    /// Runs one turn (user input → AsyncThrowingStream of events).
    let runTurn: (String) -> AsyncThrowingStream<ConversationEngine.Event, Error>

    /// Construct a real driver around a ConversationEngine.
    @MainActor
    static func live(_ engine: ConversationEngine) -> EngineDriver {
        EngineDriver(runTurn: { input in engine.runTurn(userInput: input) })
    }

    /// Test stub: a pre-canned list of turns, each with a pre-canned event list.
    struct StubTurn { let events: [ConversationEngine.Event] }
    static func stub(turns: [StubTurn]) -> EngineDriver {
        var remaining = turns
        return EngineDriver(runTurn: { _ in
            let turn = remaining.isEmpty ? StubTurn(events: [.finished]) : remaining.removeFirst()
            return AsyncThrowingStream { continuation in
                for e in turn.events { continuation.yield(e) }
                continuation.finish()
            }
        })
    }
}

/// Spec §6.5.1 FSM. One @MainActor view model owns all mutation; views read
/// @Published state.
@MainActor
final class QuickChatViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle              // can record / type
        case recording
        case thinking          // user input sent, awaiting first chunk
        case speaking          // dialog + TTS streaming
        case paused            // backgrounded / interrupted
        case summarizing       // running the local end-of-session aggregation
        case done
        case error(String)
    }

    // ---- inputs / config ----
    let phrases: [SessionPhrase]
    let suggestedTag: String?
    let progressStore: ProductionProgressStore
    private let driver: EngineDriver
    private let now: () -> Double                  // injectable clock
    private static let maxTurns = 5                // spec §9 #4

    // ---- @Published state for the view ----
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var turns: [ChatTurn] = []
    /// Phrases the session has already confirmed as correctly used. Spec §6.4
    /// session-local Set bottom — drives checklist + bounds store +1's.
    @Published private(set) var completedPhrases: Set<String> = []
    @Published private(set) var perPhraseLastNote: [String: String] = [:]
    @Published var typedInput: String = ""

    // ---- internal session state ----
    private var turnIndex = 0                       // 0 = opening
    private var written = false                     // ensure single end-of-session write

    init(phrases: [SessionPhrase],
         suggestedTag: String?,
         progressStore: ProductionProgressStore,
         engineDriver: EngineDriver,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.phrases = phrases
        self.suggestedTag = suggestedTag
        self.progressStore = progressStore
        self.driver = engineDriver
        self.now = now
    }

    /// Start the session: LLM opens the scene (no user input).
    func start() async {
        guard phase == .idle, turns.isEmpty else { return }
        await runOneTurn(userInput: "")
    }

    /// User submitted a transcribed sentence (or typed input).
    func submitUserInput(_ text: String) async {
        guard phase == .idle else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runOneTurn(userInput: trimmed)
    }

    /// User actively ends the session (close button, summary "完成").
    func endSession() async {
        await persistAndFinish()
    }

    /// Mark a phrase as correctly used (manual override "我说对了").
    /// Spec §6.4: takes the same code path as a correct verdict.
    func manuallyConfirm(_ phraseNormalized: String) {
        let wasAlreadyCompleted = completedPhrases.contains(phraseNormalized)
        completedPhrases.insert(phraseNormalized)
        if !wasAlreadyCompleted {
            SoundFX.correct()
        }
    }

    /// Move FSM to paused (scenePhase background, audio session interruption).
    func pause() {
        if phase == .recording || phase == .speaking || phase == .thinking || phase == .idle {
            phase = .paused
            Speaker.stop()
        }
    }

    /// Move back to idle from paused (user tapped "继续" after returning to foreground).
    func resume() {
        if phase == .paused { phase = .idle }
    }

    // ---- internal ----

    private func runOneTurn(userInput: String) async {
        let isOpening = userInput.isEmpty
        phase = .thinking

        // Add a user-text turn placeholder (for opening: empty user, assistant only).
        let bubble = ChatTurn(userText: userInput, assistantText: "")
        turns.append(bubble)
        let turnIdx = turns.count - 1

        do {
            for try await event in driver.runTurn(userInput) {
                switch event {
                case .dialogDelta(let s):
                    turns[turnIdx].assistantText += s
                    if phase == .thinking { phase = .speaking }
                case .sentence(let s):
                    Speaker.enqueue(s, locale: "en-US",
                                    rate: AVSpeechUtteranceDefaultSpeechRate)
                case .verdict(let v):
                    turns[turnIdx].verdict = v
                    applyVerdict(v)
                case .finished:
                    break
                }
            }
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "对话失败：\(error.localizedDescription)")
            return
        }

        turnIndex += 1
        // Hard cap on user turns. The opening turn (0) doesn't count toward the user budget.
        if !isOpening, turnIndex - 1 >= Self.maxTurns {
            await persistAndFinish()
        } else {
            phase = .idle
        }
    }

    /// Spec §6.4 session-Set + §6.5 realtime checklist + reactive feedback sound.
    private func applyVerdict(_ v: TurnVerdict) {
        var newlyCorrect: [String] = []
        for entry in v.verdicts {
            let normalized = entry.phrase   // verdict uses phraseRaw, which we set == phraseNormalized for now
            if entry.attempted && entry.correct {
                if !completedPhrases.contains(normalized) {
                    completedPhrases.insert(normalized)
                    newlyCorrect.append(normalized)
                }
            } else if entry.attempted && !entry.correct, !entry.note.isEmpty {
                perPhraseLastNote[normalized] = entry.note
            }
        }
        if !newlyCorrect.isEmpty { SoundFX.correct() }
    }

    /// End-of-session: write to ProductionProgressStore once, transition to done.
    private func persistAndFinish() async {
        guard !written else { return }
        written = true
        let nowSec = now()
        for p in phrases {
            let key = p.phraseNormalized
            if completedPhrases.contains(key) {
                progressStore.recordCorrect(phrase: key, at: nowSec)
            } else if let note = perPhraseLastNote[key] {
                progressStore.recordWrong(phrase: key, note: note, at: nowSec)
            }
            // Phrases neither correct nor noted → no store mutation (the user
            // simply didn't attempt them; not an error to record).
        }
        Speaker.stop()
        phase = .done
    }
}
```

> ⚠️ Two integration concerns this file does NOT yet wire (deferred to the View task, where they belong):
> 1. **Mic + ASR** (`AVAudioRecorder` + `SFSpeechRecognizer`) — copy-adapted from `Practice/ShadowSheet.swift:325-419`. The view binds the record button to a transcription closure that ultimately calls `vm.submitUserInput(transcribed)`.
> 2. **scenePhase / AVAudioSession interruption** observers — wire in `QuickChatView` via `.onChange(of: scenePhase)` and `NotificationCenter` for `AVAudioSession.interruptionNotification`, both calling `vm.pause()` / `vm.resume()`.

- [ ] **Step 4: Run tests to verify pass**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test -only-testing:whatsub-mobileTests/QuickChatViewModelTests
```
Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/QuickChatViewModel.swift whatsub-mobileTests/QuickChatViewModelTests.swift
git commit -m "feat(quickchat): QuickChatViewModel — FSM + session-Set + production persistence (5-turn cap)"
```

---

### Task 11: Compliance gate + first-launch modal

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/QuickChatComplianceGate.swift`

Spec §9.7 + §11 #11. v1 = single one-time modal, gated by a UserDefaults flag.

- [ ] **Step 1: Implement**

```swift
// whatsub-mobile/Practice/QuickChat/QuickChatComplianceGate.swift
import SwiftUI

/// First-launch one-time compliance notice for the QuickChat feature. Spec §9.7:
/// the dialogue is generated by the user's own configured third-party LLM
/// endpoint (default: DeepSeek). whatSub itself bundles no AI service and does
/// not store the conversation. User must tap "已了解" once; we remember.
struct QuickChatComplianceGate: View {
    @AppStorage("quickchat.compliance.acked.v1") private var acked = false
    @Binding var presenting: Bool       // bound from parent; controls sheet presentation flow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 36)).foregroundStyle(.whatsubAccent)
            Text("关于「对话陪练」")
                .font(.headline).foregroundStyle(.whatsubInk)
            Text(
                "本功能调用您在「我的 → LLM 设置」中自行配置的第三方语言模型服务进行对话。" +
                "whatSub 不内置任何语言模型服务，也不保存您的对话内容；对话仅在本机和您配置的服务之间往返。"
            )
            .font(.subheadline)
            .foregroundStyle(.whatsubInkMuted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                acked = true
                presenting = false
            } label: {
                Text("已了解").fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.whatsubAccent)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.whatsubBgElev))
        .padding(20)
    }

    /// Helper for callers: returns true if the user has already accepted.
    static var hasAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: "quickchat.compliance.acked.v1")
    }
}
```

- [ ] **Step 2: Build to confirm compile**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
```

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/QuickChatComplianceGate.swift
git commit -m "feat(quickchat): ComplianceGate — first-launch BYOK LLM disclosure (Apple §1.1/1.2 prep)"
```

---

### Task 12: Stuck card + summary view + report sheet

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/QuickChatStuckCardView.swift`
- Create: `whatsub-mobile/Practice/QuickChat/QuickChatSummaryView.swift`
- Create: `whatsub-mobile/Practice/QuickChat/ReportMessageSheet.swift`

- [ ] **Step 1: Implement `QuickChatStuckCardView.swift`**

```swift
// whatsub-mobile/Practice/QuickChat/QuickChatStuckCardView.swift
import SwiftUI

/// Popup card shown when the user taps an un-completed phrase chip — the
/// "复习救生索" of spec §6.5. Always shows the text-only review (contextSentence
/// + meaningZh + usageNote). If the phrase came from a YouTube clip, an
/// extra "▶ 看原片那一句" jumps to it (requires VPN; user has VPN if they had
/// it for the original clip viewing).
struct QuickChatStuckCardView: View {
    let phrase: SessionPhrase
    let onPlayOriginal: (() -> Void)?     // nil = no YouTube/timestamp available
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(phrase.phraseRaw)
                    .font(.headline.weight(.bold)).foregroundStyle(.whatsubInk)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                        .foregroundStyle(.whatsubInkFaint)
                }
            }
            if let meaning = phrase.meaningZh, !meaning.isEmpty {
                Text(meaning).font(.subheadline).foregroundStyle(.whatsubAccent)
            }
            if let usage = phrase.usageNote, !usage.isEmpty {
                Text(usage).font(.footnote).foregroundStyle(.whatsubInkMuted)
            }
            Divider().opacity(0.4)
            Text("当初收藏的那句：").font(.caption).foregroundStyle(.whatsubInkFaint)
            Text(phrase.contextSentence)
                .font(.system(size: 16))
                .foregroundStyle(.whatsubInk)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBg))
            if let play = onPlayOriginal {
                Button(action: play) {
                    Label("▶ 看原片那一句", systemImage: "play.rectangle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered).tint(.whatsubAccent)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.whatsubBgElev))
        .padding(.horizontal, 16)
    }
}
```

- [ ] **Step 2: Implement `QuickChatSummaryView.swift`**

```swift
// whatsub-mobile/Practice/QuickChat/QuickChatSummaryView.swift
import SwiftUI

/// End-of-session card (spec §6.5 [局末]).
struct QuickChatSummaryView: View {
    let phrases: [SessionPhrase]
    let completed: Set<String>
    let notes: [String: String]   // phraseNormalized → most recent error note
    let onPlayAgain: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("用对 \(completed.count) / \(phrases.count)")
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(.whatsubInk)
                Text(subtitle).font(.subheadline).foregroundStyle(.whatsubInkMuted)
            }
            VStack(spacing: 10) {
                ForEach(phrases) { p in row(for: p) }
            }
            .padding(.horizontal, 16)
            Spacer()
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Text("关闭").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.bordered).tint(.whatsubAccent)
                Button(action: onPlayAgain) {
                    Text("再来一局").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(.whatsubAccent)
            }
            .padding(20)
        }
        .padding(.top, 32)
    }

    private var subtitle: String {
        if completed.count == phrases.count { return "全用上了，干得漂亮 🎉" }
        if completed.isEmpty { return "下一局再试试 💪" }
        return "继续练，明天回捞剩下的"
    }

    @ViewBuilder
    private func row(for p: SessionPhrase) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: completed.contains(p.phraseNormalized) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(completed.contains(p.phraseNormalized) ? .green : .whatsubInkFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.phraseRaw).font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubInk)
                if let n = notes[p.phraseNormalized], !n.isEmpty {
                    Text(n).font(.caption).foregroundStyle(.whatsubInkMuted)
                } else if !completed.contains(p.phraseNormalized) {
                    Text("这一局没用上").font(.caption).foregroundStyle(.whatsubInkFaint)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
    }
}
```

- [ ] **Step 3: Implement `ReportMessageSheet.swift`**

```swift
// whatsub-mobile/Practice/QuickChat/ReportMessageSheet.swift
import SwiftUI
import UIKit

/// Spec §9.7 prep: long-press an assistant bubble → "上报这条回复". v1 opens a
/// `mailto:` to the admin address with the message text pre-filled — no
/// backend needed. Apple §1.1/1.2 reviewers see a working reporting path.
struct ReportMessageSheet {
    static let adminEmail = "appreview@eversay.cc"

    /// Open mail composer / share sheet pre-filled with the message text.
    /// Returns true if a mailto: URL was successfully opened.
    @discardableResult
    static func openMailReport(message: String) -> Bool {
        let subject = "举报对话陪练回复"
        let body = """
        我想举报对话陪练里这条 AI 服务返回的内容：

        ----
        \(message)
        ----

        理由（请填写）：
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = adminEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url,
              UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
```

- [ ] **Step 4: Build to confirm compile**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
```

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/QuickChatStuckCardView.swift \
        whatsub-mobile/Practice/QuickChat/QuickChatSummaryView.swift \
        whatsub-mobile/Practice/QuickChat/ReportMessageSheet.swift
git commit -m "feat(quickchat): stuck-card, summary view, mailto: report path"
```

---

### Task 13: `QuickChatView.swift` — root sheet (storyboard wiring)

This is the biggest single SwiftUI file (~250 lines). It wires:
- Header: 3-phrase chip checklist + close button.
- Body: scrolling chat transcript (user bubbles right, assistant bubbles left with long-press → report).
- Input bar: 「按麦说」 (mic) or 「打字」 (text field). Toggles between modes.
- ASR permission flow: copy-adapted from `ShadowSheet.swift:296-309`.
- 3-second countdown → `AVAudioRecorder` → on-device `SFSpeechRecognizer` (copy-adapted from `ShadowSheet.swift:325-419`).
- Stuck-card popover when user taps an un-completed phrase chip.
- Summary view (full-screen overlay) when `vm.phase == .done`.
- Compliance gate (sheet) on first appearance if `!QuickChatComplianceGate.hasAcknowledged`.
- `scenePhase` + `AVAudioSession.interruptionNotification` → `vm.pause()` / `vm.resume()`.

**Files:**
- Create: `whatsub-mobile/Practice/QuickChat/QuickChatView.swift`

- [ ] **Step 1: Implement the view (large; full code below)**

```swift
// whatsub-mobile/Practice/QuickChat/QuickChatView.swift
import SwiftUI
import AVFoundation
import Speech
import UIKit

/// QuickChat root sheet. The product surface of spec §6.5.
struct QuickChatView: View {
    let phrases: [SessionPhrase]
    let suggestedTag: String?

    @StateObject private var vm: QuickChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // Compliance gate
    @State private var showCompliance: Bool
    // Stuck card
    @State private var stuckPhrase: SessionPhrase?
    // Input mode
    @State private var typingMode: Bool = false
    // Mic + ASR state
    @State private var micPhase: MicPhase = .idle
    @State private var countdown: Int = 0
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var micPermissionDenied = false

    enum MicPhase: Equatable {
        case idle, countdown, recording, transcribing
    }

    init(phrases: [SessionPhrase], suggestedTag: String?,
         progressStore: ProductionProgressStore = ProductionProgressStore(),
         settings: LlmSettings = LlmSettingsStore.load()) {
        self.phrases = phrases
        self.suggestedTag = suggestedTag
        let client = ChatCompletionsClient(settings: settings)
        let systemPrompt = QuickChatPrompts.systemPrompt(phrases: phrases, suggestedTag: suggestedTag)
        let engine = ConversationEngine(client: client, systemPrompt: systemPrompt)
        _vm = StateObject(wrappedValue: QuickChatViewModel(
            phrases: phrases, suggestedTag: suggestedTag,
            progressStore: progressStore,
            engineDriver: .live(engine)
        ))
        _showCompliance = State(initialValue: !QuickChatComplianceGate.hasAcknowledged)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.whatsubBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerChips
                    transcriptScroll
                    inputBar
                }
                if vm.phase == .done {
                    QuickChatSummaryView(
                        phrases: phrases,
                        completed: vm.completedPhrases,
                        notes: vm.perPhraseLastNote,
                        onPlayAgain: { dismiss() },     // re-pick from CorpusView entry
                        onClose: { dismiss() }
                    )
                    .background(Color.whatsubBg.ignoresSafeArea())
                }
            }
            .navigationTitle("对话陪练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { Task { await vm.endSession(); dismiss() } }
                }
            }
            .sheet(isPresented: $showCompliance) {
                QuickChatComplianceGate(presenting: $showCompliance)
                    .presentationDetents([.medium])
            }
            .sheet(item: $stuckPhrase) { p in
                QuickChatStuckCardView(
                    phrase: p,
                    onPlayOriginal: youtubeOpener(for: p),
                    onDismiss: { stuckPhrase = nil }
                )
                .presentationDetents([.medium])
            }
        }
        .task {
            await requestPermissions()
            if !showCompliance { await vm.start() }
        }
        .onChange(of: showCompliance) { showing in
            // After the user dismisses the compliance gate, start the dialogue.
            if !showing, vm.turns.isEmpty { Task { await vm.start() } }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { vm.pause() }
            else if vm.phase == .paused { vm.resume() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            // Phone call / Siri / etc. — pause for safety.
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { vm.pause() }
        }
    }

    // ---- header chips ----
    private var headerChips: some View {
        HStack(spacing: 8) {
            ForEach(phrases) { p in
                Button { stuckPhrase = p } label: {
                    HStack(spacing: 4) {
                        Image(systemName: vm.completedPhrases.contains(p.phraseNormalized) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vm.completedPhrases.contains(p.phraseNormalized) ? .green : .whatsubInkFaint)
                        Text(p.phraseRaw)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(.whatsubInk)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.whatsubBgElev))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    // ---- transcript ----
    @ViewBuilder
    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            if !turn.userText.isEmpty {
                                bubble(turn.userText, isUser: true)
                            }
                            if !turn.assistantText.isEmpty {
                                bubble(turn.assistantText, isUser: false)
                                    .contextMenu {
                                        Button {
                                            ReportMessageSheet.openMailReport(message: turn.assistantText)
                                        } label: { Label("上报这条回复", systemImage: "exclamationmark.bubble") }
                                    }
                            }
                        }
                        .id(turn.id)
                    }
                    if case .thinking = vm.phase {
                        ProgressView().tint(.whatsubAccent).padding(.leading, 12)
                    }
                    if case .error(let msg) = vm.phase {
                        Text(msg).font(.caption).foregroundStyle(.red).padding()
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .onChange(of: vm.turns.last?.assistantText ?? "") { _ in
                withAnimation { proxy.scrollTo(vm.turns.last?.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 30) }
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.whatsubInk)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(isUser ? Color.whatsubAccent.opacity(0.18) : Color.whatsubBgElev))
            if !isUser { Spacer(minLength: 30) }
        }
    }

    // ---- input bar ----
    @ViewBuilder
    private var inputBar: some View {
        if micPermissionDenied || typingMode {
            HStack(spacing: 8) {
                TextField("打字回应…", text: $vm.typedInput, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
                Button {
                    let text = vm.typedInput
                    vm.typedInput = ""
                    Task { await vm.submitUserInput(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(.whatsubAccent)
                }
                .disabled(vm.typedInput.trimmingCharacters(in: .whitespaces).isEmpty || vm.phase != .idle)
                if !micPermissionDenied {
                    Button { typingMode = false } label: {
                        Image(systemName: "mic.fill").foregroundStyle(.whatsubAccent)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.whatsubBg)
        } else {
            HStack(spacing: 12) {
                micButton
                Button { typingMode = true } label: {
                    Image(systemName: "keyboard").foregroundStyle(.whatsubAccent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.whatsubBg)
        }
    }

    @ViewBuilder
    private var micButton: some View {
        switch micPhase {
        case .idle:
            Button { Task { await startCountdown() } } label: {
                Label("按麦说", systemImage: "mic.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.whatsubAccent)
            .disabled(vm.phase != .idle)
        case .countdown:
            Text("\(countdown)…").font(.title2.weight(.bold)).foregroundStyle(.whatsubAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubAccent.opacity(0.15)))
        case .recording:
            Button { stopRecording() } label: {
                Label("停止", systemImage: "stop.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.red)
        case .transcribing:
            HStack { ProgressView().tint(.whatsubAccent); Text("识别中…").font(.subheadline) }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
    }

    // ---- permissions + mic/ASR (adapted from ShadowSheet.swift) ----

    private func requestPermissions() async {
        let mic: Bool
        if #available(iOS 17.0, *) {
            mic = await AVAudioApplication.requestRecordPermission()
        } else {
            mic = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { st in cont.resume(returning: st == .authorized) }
        }
        if !(mic && speech) { micPermissionDenied = true; typingMode = true }
    }

    private func startCountdown() async {
        guard !micPermissionDenied else { return }
        micPhase = .countdown
        for n in stride(from: 3, through: 1, by: -1) {
            countdown = n
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        startRecording()
    }

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            micPhase = .idle
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qc-\(UUID().uuidString).m4a")
        recordingURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            micPhase = .recording
            // 20-second hard cap (sentences are short).
            Task { [weak r] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if r?.isRecording == true { await MainActor.run { stopRecording() } }
            }
        } catch {
            micPhase = .idle
        }
    }

    private func stopRecording() {
        recorder?.stop(); recorder = nil
        guard let url = recordingURL else { micPhase = .idle; return }
        micPhase = .transcribing
        Task { await transcribe(url) }
    }

    private func transcribe(_ url: URL) async {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let r = recognizer, r.isAvailable else {
            micPhase = .idle; typingMode = true
            return
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        do {
            let text: String = try await withCheckedThrowingContinuation { cont in
                var done = false
                r.recognitionTask(with: req) { result, error in
                    if done { return }
                    if let error { done = true; cont.resume(throwing: error); return }
                    if let result, result.isFinal {
                        done = true
                        cont.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
            try? FileManager.default.removeItem(at: url)
            micPhase = .idle
            await vm.submitUserInput(text)
        } catch {
            micPhase = .idle
        }
    }

    // ---- youtube replay (best-effort: only youtube + timestamp) ----
    private func youtubeOpener(for p: SessionPhrase) -> (() -> Void)? {
        // `extractYouTubeID` is a free function (see Corpus/YouTubeID.swift).
        guard p.sourceKind == "youtube",
              let ts = p.sourceTimestampSec,
              let videoID = extractYouTubeID(p.sourceURL) else { return nil }
        return {
            // Open a deep link to the existing YouTubeEmbedView is overkill for v1;
            // we just open the canonical youtu.be URL with t= so the system browser
            // (or YouTube app, if installed) jumps to the right second.
            let url = URL(string: "https://youtu.be/\(videoID)?t=\(Int(ts))")!
            UIApplication.shared.open(url)
        }
    }
}
```

- [ ] **Step 2: Build to confirm compile**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
```

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Practice/QuickChat/QuickChatView.swift
git commit -m "feat(quickchat): QuickChatView — full storyboard (chips, transcript, mic+ASR, summary, compliance)"
```

---

### Task 14: Entry point in `CorpusView.swift`

**Files:**
- Modify: `whatsub-mobile/Corpus/CorpusView.swift`

Add a 「对话陪练」 button beside the existing 「单词卡」 button. Tap → assemble a session (run selector against `vm.mine` + the two stores) → present `QuickChatView` as a sheet.

- [ ] **Step 1: Add state + sheet presentation + selector wiring**

In `whatsub-mobile/Corpus/CorpusView.swift`, at the existing `@State` declarations (currently `showQuiz` + `showSubscribe`), add:

```swift
    @State private var showQuickChat: Bool = false
    @State private var quickChatPick: PhraseSelector.Pick?
    @State private var quickChatColdStart: Bool = false
```

In the header `HStack` (currently the row with 「语料库」 title + 「单词卡」 button), insert a new button immediately before the 「单词卡」 one:

```swift
                    Button { tapQuickChat() } label: {
                        Label("对话陪练", systemImage: "bubble.left.and.bubble.right")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.whatsubAccent)
                    }
```

At the bottom of `body` (right after the existing `.sheet(isPresented: $showSubscribe) { ... }`), add:

```swift
            .sheet(isPresented: $showQuickChat) {
                if let pick = quickChatPick {
                    QuickChatView(phrases: pick.phrases, suggestedTag: pick.suggestedTag)
                        .environmentObject(appState)
                }
            }
            .alert("语料不够", isPresented: $quickChatColdStart) {
                Button("好") { quickChatColdStart = false }
            } message: {
                Text("先用插件划词收藏 3 个以上短语就可以开练。")
            }
```

Add the `tapQuickChat()` method at the bottom of `CorpusView`:

```swift
    private func tapQuickChat() {
        // Pull mine items + the two progress stores; run the pure selector.
        let prodStore = ProductionProgressStore()
        let quizStore = QuizProgressStore()
        let pick = PhraseSelector.pick(
            from: vm.mine,
            isRecognized: { quizStore.progress(for: $0).isMastered },
            productionMastered: { prodStore.progress(for: $0)?.masteredAt != nil },
            isDueForRepetition: { prodStore.isDueForRepetition(phrase: $0, now: Date().timeIntervalSince1970) },
            now: Date().timeIntervalSince1970
        )
        if let p = pick {
            quickChatPick = p
            showQuickChat = true
        } else {
            quickChatColdStart = true
        }
    }
```

- [ ] **Step 2: Build to confirm compile**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
```

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Corpus/CorpusView.swift
git commit -m "feat(quickchat): entry button in CorpusView header (gated on language >=3 mine items)"
```

---

### Task 15: Broaden mic + speech permission descriptions in `project.yml`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Edit lines 83-84**

Replace:

```yaml
        NSMicrophoneUsageDescription: "用于跟读练习时录下你的发音并与字幕原文做对比评分。"
        NSSpeechRecognitionUsageDescription: "将跟读练习的录音转为文字以与字幕原文做逐词比对。所有识别在本机完成。"
```

With:

```yaml
        NSMicrophoneUsageDescription: "用于跟读练习和对话陪练时录下你的发音，与字幕原文或目标短语做对比。"
        NSSpeechRecognitionUsageDescription: "把跟读练习和对话陪练里的录音转为文字，用于与字幕原文做逐词比对、或判断目标短语是否被正确使用。所有识别在本机完成。"
```

- [ ] **Step 2: Regenerate project + build smoke**

```bash
xcodegen generate
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build -quiet
```
Expected: green.

- [ ] **Step 3: Commit**

```bash
git add project.yml
git commit -m "chore(plist): broaden mic + speech permission copy to cover QuickChat (对话陪练)"
```

---

### Task 16: Final spec-coverage sweep + manual TestFlight smoke

This is the only non-code task. Two checklists.

**Files:**
- Modify (notes only): `docs/superpowers/specs/2026-05-31-ai-voice-practice-corpus.md` (mark §11 acceptance criteria with ✅ after manual verification)

- [ ] **Step 1: Run the full test suite locally (or via CI artifact)**

```bash
xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test
```
Expected: every test target green, including all six new test files.

- [ ] **Step 2: Compliance / wording audit (do BEFORE pushing to TestFlight)**

Run this grep — output must be empty. **Use word-boundary regex** so it doesn't false-positive on `isAvailable` ("ai"), `mainActor` ("ai"), etc.:

```bash
grep -rEni "\b(AI|ChatGPT|OpenAI|GPT)\b" whatsub-mobile/Practice/QuickChat/ whatsub-mobile/Corpus/CorpusView.swift
```

Also scrub any UI string (Chinese):

```bash
grep -rn "AI 助理\|智能对话\|大模型助手\|大模型助理" whatsub-mobile/Practice/QuickChat/ whatsub-mobile/Corpus/CorpusView.swift
```

Both expected: zero hits. (Per spec §9.7 / §11 #12; any hit fails App Store review again.)

- [ ] **Step 3: Manual TestFlight smoke test path** (after the TestFlight build promotes)

Run through each acceptance criterion in spec §11 (1–13). For each, mark ✅ in the spec file or open an issue. The non-obvious ones to actively test:

1. ✅ §11.5 streaming: start a session, watch the chat bubble fill chunk-by-chunk + hear TTS before the bubble finishes.
2. ✅ §11.7 mid-session exit: start a session, get one ✓ on the checklist, hit 「关闭」, then run another session — confirm the closed phrase's `usedCorrectCount` did increment in the local `production_progress.json` (read from sim/device sandbox).
3. ✅ §11.10 5-turn hard cap: speak 5 times, observe auto-summary on turn 5 even if all phrases are unused.
4. ✅ §11.11 compliance + report: first-launch shows the gate; after dismissing, long-press an assistant bubble → mail app opens with prefilled subject/body.

- [ ] **Step 4: Commit verification note**

```bash
git commit --allow-empty -m "test: QuickChat v1 — all §11 acceptance criteria verified on TestFlight"
```

- [ ] **Step 5: Push + watch TestFlight workflow**

```bash
git push origin main
gh run list --workflow=testflight.yml --limit=1 --repo rjxznb/whatsub-mobile
```

After the build promotes, walk through §11 acceptance criteria on a real device (especially mic + ASR).

---

## Self-Review Notes

(Following the writing-plans skill's self-review checklist — failures of any item should be patched here before execution.)

**Spec coverage scan** (each spec § → covering task):
- §0 spike findings → Tasks 4 (prompt), 5 (parser), 9 (Speaker), 10 (session-Set). All three v2 patches incorporated.
- §1–§4 (positioning + 3-store + tier model) → Tasks 1, 2.
- §5 ProductionProgressStore → Task 2.
- §6.1 selector → Task 3.
- §6.2 streaming + prompt → Tasks 4, 7, 8.
- §6.3 v1 single-language TTS → Task 9.
- §6.4 verdict semantics + session-Set + manual override → Tasks 5, 10.
- §6.5 storyboard → Tasks 11, 12, 13.
- §6.5.1 FSM + interrupt handling → Task 10 (FSM), Task 13 (scenePhase + AVAudioSession observers).
- §6.6 entry point → Task 14.
- §7 data flow → covered end-to-end by Tasks 1+2+3+8+10+13+14.
- §8 zero-backend → no backend file modified anywhere in this plan.
- §9 risks: 1,2,3 (delay) → Tasks 7,8,9; 4 (token + 5-turn cap) → Task 10 (`maxTurns = 5`); 5 (permissions) → Tasks 13, 15; 6 (cold start) → Task 14; 7 (compliance) → Tasks 11, 12, 16; 8 (LlmSettings shared) → no code change; 9 (mastery threshold) → Task 2 (`masteryThreshold = 2`).
- §10 reuse/new file map → Tasks 1–14 cover every entry.
- §11 acceptance → Task 16.

**Placeholder scan**: searched for "TBD", "implement later", "add appropriate", "similar to Task" — none. Every code step shows complete code.

**Type / name consistency**: `phraseNormalized` is used consistently as the key everywhere (selector, models, store, session-Set). `SessionPhrase` is the only shape passed between selector / prompt / view model. `TurnVerdict` / `PhraseVerdict` JSON shapes match the prompt template in QuickChatPrompts. `EngineDriver.runTurn(_:)` signature matches `ConversationEngine.runTurn(userInput:)`.

**One known nuance** (noted inline in Task 3): the `Cand` type appearing both nested in `pick(...)` and at enum scope. The plan instructs the implementer to hoist it. If they miss this and get a Swift compile error, the plan tells them where to look.

**One known scope deferral** (intentional, noted in spec §3.2 + §12): production-progress cross-device sync, bilingual TTS routing, public-corpus pool. These are NOT in any task and that's correct.

---

## Out-of-Scope (Reminders, not Tasks)

- DO NOT modify `whatsub-license` backend — every part of QuickChat runs on-device + BYOK.
- DO NOT add markdown / emoji stripping in `Speaker` — spike confirmed LLM output is clean prose; YAGNI.
- DO NOT split out a `BilingualTTS.swift` — explicitly deferred to v1.1 per spec §6.3 + §12.
- DO NOT add a verdict-only fallback LLM call — spike measured 5/5 verdict adherence; YAGNI.
- DO NOT push to main without first running Task 16 Step 2 grep (App Store compliance gate).
