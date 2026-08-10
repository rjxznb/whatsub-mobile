# Highlight Word Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a tapped highlighted subtitle phrase pause the video, speak standard English, show IPA/meaning, and offer duplicate-safe one-tap collection.

**Architecture:** Keep `CueRow`'s existing highlighted-link routing and enhance the existing `GlossSheet`; do not add a second overlay or collection store. Put phrase normalization and duplicate prevention in `PendingPhraseStore`, then let both the sheet UI and tests consume that single source of truth. `LibraryDetailView` remains responsible for pausing its shared player before presenting the word card.

**Tech Stack:** Swift 5.10, SwiftUI, AVFoundation through existing `Speaker`, XCTest, XcodeGen, iOS 16+.

## Global Constraints

- Standard pronunciation must work without video, network, or VPN.
- Collection writes only to the existing local pending store and does not consume cloud quota immediately.
- Duplicate scope is the same Library `entryId` plus a case-insensitive, whitespace-normalized phrase.
- The same phrase from different videos remains collectable.
- Existing ordinary cue seeking and long-press collect/shadow/cloze/copy actions must remain available.
- Closing the word card must not resume video playback.
- No third-party Swift dependency may be introduced.

---

### Task 1: Duplicate-safe pending collection

**Files:**
- Modify: `whatsub-mobile/Vocab/PendingPhraseStore.swift`
- Create: `whatsub-mobileTests/PendingPhraseStoreTests.swift`

**Interfaces:**
- Produces: `PendingPhraseStore.contains(entryId:phraseRaw:) -> Bool`
- Produces: `PendingPhraseStore.addIfAbsent(_:) -> Bool`, returning `true` only when a row is appended.
- Internal comparison key: trim, collapse runs of whitespace to one space, and lowercase with a stable locale-independent comparison.

- [ ] **Step 1: Write failing store tests**

Create tests using a unique temporary JSON path and real `PendingPhrase` values:

```swift
func testAddIfAbsentRejectsSamePhraseInSameEntryIgnoringCaseAndWhitespace() {
    let store = makeStore()
    XCTAssertTrue(store.addIfAbsent(makePhrase(entryId: "video-a", phrase: "Welcome   Back")))
    XCTAssertFalse(store.addIfAbsent(makePhrase(entryId: "video-a", phrase: " welcome back ")))
    XCTAssertEqual(store.total, 1)
    XCTAssertTrue(store.contains(entryId: "video-a", phraseRaw: "WELCOME BACK"))
}

func testAddIfAbsentAllowsSamePhraseInDifferentEntries() {
    let store = makeStore()
    XCTAssertTrue(store.addIfAbsent(makePhrase(entryId: "video-a", phrase: "welcome back")))
    XCTAssertTrue(store.addIfAbsent(makePhrase(entryId: "video-b", phrase: "welcome back")))
    XCTAssertEqual(store.total, 2)
}
```

- [ ] **Step 2: Push RED test commit and run branch CI**

Run locally:

```powershell
git add whatsub-mobileTests/PendingPhraseStoreTests.swift
git commit -m "test: cover pending phrase duplicate prevention"
git push -u origin codex/highlight-word-actions
gh workflow run ci.yml --ref codex/highlight-word-actions
```

Expected: CI test failure because `contains(entryId:phraseRaw:)` and `addIfAbsent(_:)` do not exist.

- [ ] **Step 3: Implement minimal duplicate prevention**

Add a private normalizer and the two query/mutation methods. `addIfAbsent` must call `contains` before appending and persist only when insertion occurs:

```swift
func contains(entryId: String, phraseRaw: String) -> Bool {
    let key = Self.normalizedPhrase(phraseRaw)
    return items.contains {
        $0.entryId == entryId && Self.normalizedPhrase($0.phraseRaw) == key
    }
}

@discardableResult
func addIfAbsent(_ phrase: PendingPhrase) -> Bool {
    guard !contains(entryId: phrase.entryId, phraseRaw: phrase.phraseRaw) else { return false }
    items.append(phrase)
    save()
    return true
}
```

The normalizer must use `split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()` so tabs/newlines and repeated spaces behave consistently.

- [ ] **Step 4: Run branch CI for GREEN**

Commit and push, then run `ci.yml` on the branch. Expected: the new store tests and the complete existing suite pass.

- [ ] **Step 5: Commit implementation**

```powershell
git add whatsub-mobile/Vocab/PendingPhraseStore.swift
git commit -m "feat: prevent duplicate pending phrases"
```

---

### Task 2: Pronouncing compact word card

**Files:**
- Modify: `whatsub-mobile/Library/GlossSheet.swift`
- Create: `whatsub-mobileTests/HighlightWordActionsSourceTests.swift`

**Interfaces:**
- Consumes: `Speaker.speak(_:)`, `Speaker.stop()`, `IPADict.shared.lookup(_:)`.
- Consumes: `PendingPhraseStore.contains(entryId:phraseRaw:)` and `addIfAbsent(_:)` from Task 1.
- Keeps: `GlossSheet(gloss:)` call site unchanged.

- [ ] **Step 1: Write failing source-contract test**

Read `GlossSheet.swift` as UTF-8 and assert the user-visible contract:

```swift
XCTAssertTrue(source.contains("Speaker.speak(gloss.word)"))
XCTAssertTrue(source.contains("IPADict.shared.lookup(gloss.word)"))
XCTAssertTrue(source.contains("Speaker.stop()"))
XCTAssertTrue(source.contains("addIfAbsent(pending)"))
XCTAssertTrue(source.contains("Text(saved ? \"已收藏\" : \"收藏\")"))
XCTAssertTrue(source.contains("presentationDetents([.height("))
```

Also assert the source still includes a separate replay button with accessibility label `再次播放发音`.

- [ ] **Step 2: Push RED test and run branch CI**

Commit/push only the new test and trigger `ci.yml`. Expected: failure because pronunciation, IPA, compact detent, and new button copy are absent.

- [ ] **Step 3: Implement the word-card UI**

Update `GlossSheet` so it:

- uses `.task(id: gloss.id)` to call `Speaker.speak(gloss.word)` exactly once per presentation;
- calls `Speaker.stop()` in `.onDisappear`;
- shows `IPADict.shared.lookup(gloss.word)` beneath the highlighted phrase when non-nil;
- places a replay button beside the phrase and labels it `再次播放发音`;
- uses a compact `.presentationDetents([.height(340)])` with a visible drag indicator and retains `ScrollView` for Dynamic Type;
- derives initial saved state from `PendingPhraseStore.shared.contains(...)`;
- changes the prominent CTA to `收藏` / `已收藏` with bookmark/checkmark icons;
- calls `addIfAbsent(pending)` and only fires success haptics when insertion succeeds.

- [ ] **Step 4: Run branch CI for GREEN**

Commit/push and trigger `ci.yml`. Expected: source-contract test passes, app compiles for simulator, full unit suite passes, screenshot artifact is generated.

- [ ] **Step 5: Commit implementation**

```powershell
git add whatsub-mobile/Library/GlossSheet.swift
git commit -m "feat: add pronunciation to highlight word card"
```

---

### Task 3: Pause playback and preserve existing gestures

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Modify: `whatsub-mobile/Library/EntryCollectionsList.swift`
- Modify: `whatsub-mobileTests/HighlightWordActionsSourceTests.swift`

**Interfaces:**
- Consumes: existing `@State avPlayer` in `LibraryDetailView`.
- Keeps: `CueRow.onTapCue`, `onCollect`, `onShadow`, `onCloze`, and copy context-menu behavior.

- [ ] **Step 1: Extend the failing source-contract test**

Assert that the highlighted-word callback pauses playback before assigning `glossWord`, that the `CueRow` context menu still contains its four actions, and that the collections empty-state copy mentions both tapping a highlighted word and long-pressing a sentence.

- [ ] **Step 2: Run branch CI to verify RED**

Expected: failure because the player is not paused and the old empty-state copy only teaches long press.

- [ ] **Step 3: Implement minimal integration**

Insert `avPlayer?.pause()` as the first action in `onTapHighlight`, before constructing `WordGloss`. Update only the instructional empty-state sentence in `EntryCollectionsList`; do not change `CueRow` gesture wiring or context-menu actions.

- [ ] **Step 4: Run branch CI for GREEN**

Expected: complete simulator build and test suite pass with the new integration assertions.

- [ ] **Step 5: Commit integration**

```powershell
git add whatsub-mobile/Library/LibraryDetailView.swift whatsub-mobile/Library/EntryCollectionsList.swift whatsub-mobileTests/HighlightWordActionsSourceTests.swift
git commit -m "feat: pause video for highlight pronunciation"
```

---

### Task 4: Final verification and delivery

**Files:**
- Verify all branch changes.

**Interfaces:**
- No new interfaces.

- [ ] **Step 1: Inspect scope and formatting**

Run:

```powershell
git status --short
git diff main...HEAD --check
git diff --stat main...HEAD
```

Expected: only the spec, plan, two production areas, copy update, and focused tests are changed; no whitespace errors.

- [ ] **Step 2: Run fresh full macOS CI**

Trigger and watch `ci.yml` on `codex/highlight-word-actions`. Require archive output showing simulator build success, zero failed tests, successful app install/launch, and screenshot upload.

- [ ] **Step 3: Review screenshot artifact**

Download/view the CI screenshot when it reaches the relevant screen if available. If CI only captures launch state, rely on compile/tests and explicitly report that the interactive sheet still needs TestFlight device verification.

- [ ] **Step 4: Review requirements line by line**

Check the design spec goals: autoplay pronunciation, pause, IPA, replay, one-tap pending collection, same-entry dedupe, cross-entry allowance, no auto-resume, and preserved long-press actions.

- [ ] **Step 5: Commit any documentation bookkeeping, then choose integration**

Use the branch-finishing workflow after all verification is fresh. Do not merge, push `main`, or publish TestFlight unless the user authorizes that delivery action.
