# Corpus Quiz (单词卡测验) — Design

**Date:** 2026-05-24
**Status:** design — pending user review before plan

## Problem / Goal

A flashcard quiz on the phone to drill the corpus phrases: pull a random phrase, show the English phrase + several Chinese-meaning options; a wrong pick gets an ✗ and the user keeps trying until correct; on correct, reveal that phrase's corpus content; 继续 → next phrase. Progress persists locally so closing the app doesn't lose it.

## Key decisions (locked in brainstorming)

1. **Client-side only — NO backend change.** Reuses the existing `/api/corpus/browse` + `/api/corpus/mine`; progress is stored locally on the device.
2. **Scope picker, not merged.** On entering the quiz the user picks **公共** (`browseCorpus`, license-gated) OR **个人** (`mineCorpus`, session-only). One scope per quiz run — avoids cross-scope merge complexity.
3. **4-option multiple choice.** Prompt = English `phraseRaw`; options = the correct `meaningZh` + 3 distractor `meaningZh` drawn at random from OTHER phrases in the same pool; options shuffled.
4. **Wrong → ✗ + retry.** A wrong tap marks that option with ✗, disables it (stays visible), and the user keeps tapping until the correct one. 
5. **Correct → lightweight inline reveal.** Show the phrase's content from data already in the pool — `meaningZh` + `usageNote` + (personal scope) `contextSentence` — plus a 继续 button and an optional "看完整详情" link that pushes the existing `PhraseDetailView`.
6. **Persistent local progress.** A JSON file written after EACH completed phrase (survives app close), keyed by `phraseNormalized`.
7. **Mastery + weighted selection.** Mastered = `correctFirstTry ≥ 2`. Selection is weighted random favoring unseen / previously-wrong over mastered, to push the user through the whole library. Header shows 已掌握 X / 共 Y + this-session streak.
8. **Entry:** a button at the top of the 语料库 tab.

## Architecture / components (all in `whatsub-mobile`, iOS)

- **`QuizCard`** (model, `Quiz/QuizModels.swift`): `{ phraseNormalized: String, phraseRaw: String, meaningZh: String, usageNote: String?, contextSentence: String? }` — a unified card built from `BrowsePhrase` (public) or `MineItem` (personal). Only phrases with a non-empty `meaningZh` become cards.
- **`QuizProgress`** (model): `{ seen: Int, correctFirstTry: Int, wrong: Int, lastSeenAt: Int64 }`; `var isMastered: Bool { correctFirstTry >= 2 }`.
- **`QuizProgressStore`** (`Quiz/QuizProgressStore.swift`): loads/saves `Documents/quiz_progress.json` as `{ version: 1, phrases: [phraseNormalized: QuizProgress] }`. API: `progress(for:) -> QuizProgress`, `record(phraseNormalized:firstTryCorrect:wrongCount:)` (mutates + writes immediately), `masteredCount(in pool: [String]) -> Int`, `reset(scopePhrases:)`. Atomic write (write to temp + replace). Missing/corrupt file → empty store.
- **`QuizViewModel`** (`Quiz/QuizViewModel.swift`, `@MainActor ObservableObject`): owns the chosen scope, the `[QuizCard]` pool, the current `Question` (card + shuffled options + which are ruled-out), the session streak, and a `QuizProgressStore`. Builds questions, runs the weighted selection, records results. Calls `WhatsubAPI`.
- **`QuizView`** (`Quiz/QuizView.swift`): scope picker → card UI (English prompt, 4 option buttons with ✗/disabled state, reveal panel, 继续) + a header progress line. Insufficient-pool + all-mastered states.
- **`CorpusView`** (existing, modified): a "单词卡测验" entry button/row at the top → `NavigationLink`/sheet to `QuizView`.
- **Reuse:** `WhatsubAPI.browseCorpus(tags:token:)` / `mineCorpus(tags:token:)`, the `BrowsePhrase` / `MineItem` DTOs, `PhraseDetailView` (optional link). Token via `appState.session?.sessionToken`.

## Data flow

1. User taps 单词卡测验 → QuizView → picks scope (公共/个人).
2. Fetch pool: public → `browseCorpus(tags: [], token:)`; personal → `mineCorpus(tags: [], token:)`. Map to `[QuizCard]` keeping only entries with a non-empty `meaningZh`; de-duplicate by `phraseNormalized` (personal may have multiple rows per phrase — keep the first).
3. If pool `< 4` → show "短语不够测验（至少需要 4 个有释义的短语）".
4. Load `QuizProgressStore`. Select a card by weighted random (below) → build a `Question`: correct option = card.meaningZh; 3 distractors = random distinct `meaningZh` from other cards whose meaning text ≠ the correct text; shuffle the 4.
5. User taps options; wrong → add to ruled-out set (✗, disabled); correct → record progress (`firstTryCorrect = ruledOut.isEmpty`, `wrongCount = ruledOut.count`), write file, show reveal.
6. 继续 → select the next card (avoid immediately repeating the same `phraseNormalized`).

### Weighted selection
Bucket the pool by progress: **A** = unseen OR `wrong > 0 and not mastered`; **B** = seen, not mastered, no recent wrong; **C** = mastered. Pick from the first non-empty bucket in order A→B→C with random choice inside it (so mastered cards still reappear occasionally once A/B are exhausted). Never pick the card just answered (unless it's the only one). If ALL cards are mastered → show "本库已全部掌握 🎉" with a 重置本库进度 button (`store.reset(scopePhrases:)`).

## Persistence schema

`Documents/quiz_progress.json`:
```json
{ "version": 1, "phrases": { "<phraseNormalized>": { "seen": 3, "correctFirstTry": 2, "wrong": 1, "lastSeenAt": 1716500000000 } } }
```
- Written immediately after each completed phrase (atomic: write temp file → `replaceItemAt`).
- Loaded once on quiz start.
- Missing file or decode failure → start from an empty store (never crash).
- Keyed by `phraseNormalized` globally — a phrase's mastery is shared across scopes (a phrase is a phrase). "共 Y" in the header is computed against the CURRENT scope's pool only.

## Error handling

- Public scope without an active license → `browseCorpus` returns an error/empty; show "公共语料库需要授权后才能测验" with a hint to use 个人 scope or buy a license. Personal scope needs only a session.
- Network failure fetching the pool → an error state with a 重试 button.
- Empty `meaningZh` across the pool → treated as insufficient (`< 4`).
- All distractors identical to the correct meaning (tiny pool with duplicate meanings) → fall back to fewer options (min 2) rather than crash; if only the correct meaning exists, treat the pool as insufficient.

## Testing

- **`QuizProgressStore`** (unit): save→load round-trip; `record()` increments `seen`/`correctFirstTry`/`wrong` correctly + `lastSeenAt` set; missing file → empty; corrupt JSON → empty (no throw); `reset(scopePhrases:)` clears only those keys.
- **`QuizViewModel`** (unit, mock API + in-memory store): question always contains the correct option; distractors are distinct and never equal the correct meaning text; pool `< 4` → insufficient state; weighted selection deprioritizes mastered (given a pool with some mastered + some unseen, the next pick is unseen); `firstTryCorrect` recorded true only when no wrong taps.
- **Manual e2e (TestFlight):** 语料库 → 单词卡测验 → 公共/个人 → tap a wrong option (✗ shows, disabled) → tap correct → reveal shows meaning+usage → 继续 → next; force-quit + reopen → progress persisted (已掌握 count retained); exhaust a small 个人 pool → 🎉 + 重置 works.

## Out of scope (v1)

- Merged cross-scope pool (scopes are picked separately).
- Server-synced progress (local only).
- Reverse direction (中→英) or typed answers (multiple-choice 英→中 only).
- Interval-based SRS scheduling (v1 is weighted-random + a mastery threshold).
- Audio / pronunciation.
