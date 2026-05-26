# iOS 词汇本 (per-video vocab notebook) — Design + Plan

**Date:** 2026-05-26
**Status:** approved (interaction = 方案甲 collect-card + rich notes; delete-migration approved)

## Goal

While close-reading a synced video's bilingual subtitles, let the user save **any**
phrase (not just the AI-highlighted ones) — with a personal **note** — into a
**per-video** vocab notebook. Local storage only, no backend. Deleting a video no
longer silently drops its notebook: the user can **migrate** the phrases to a
**staging area** or to **another video** first.

## Decisions (from brainstorming)

- **Add interaction = 方案甲 (collect card):** tap a cue = seek (unchanged);
  **long-press** a cue opens a 收藏卡 sheet for that sentence. In the card the
  sentence is **selectable** (UIKit text view) — select any word/phrase → 「加入词汇本」
  (nothing selected ⇒ saves the whole sentence). The card also has a **笔记**
  editor (the user wanted richer notes, not just 中英文) and shows the AI 释义 of any
  highlight in the sentence as reference.
- **View = reader top-bar button:** a 「词汇本」toolbar button (book icon + count
  badge) in the portrait reader → that video's saved-phrase list (tap → seek to the
  cue + dismiss; swipe → delete; tap a row's note to edit).
- **Delete-migration:** Library swipe-delete, if the notebook is non-empty, shows a
  dialog → 迁移到暂存区 / 迁移到其他视频 / 一起删除. The **暂存区** is a special global
  notebook (`entryId == "__staging__"`), viewable from the 我的 tab.
- **The old long-press → 释义 popup is folded into the collect card** (释义 shown there
  as reference); the standalone `highlightPopup` is removed from the view.

## Data model + storage

`Documents/vocab_notebooks.json` = `[String: [VocabItem]]` (entryId → items;
`"__staging__"` for the staging area). Loaded on init, rewritten after each mutation
— same pattern as `Documents/quiz_progress.json`.

```swift
struct VocabItem: Codable, Identifiable, Equatable {
    let id: String            // UUID().uuidString
    var phrase: String        // the saved phrase (selection or whole sentence)
    var sentenceEn: String    // full cue English (context)
    var translationZh: String // cue Chinese (context)
    var note: String          // user's rich note (may be empty)
    var cueIndex: Int?         // jump-back target; nil once cross-video migrated
    var sourceTitle: String?   // originating video title (shown in staging)
    let savedAt: Double        // epoch seconds
}
```

## Files

### New — `whatsub-mobile/Vocab/`
- **`VocabModels.swift`** — `VocabItem` (above).
- **`VocabStore.swift`** — `@MainActor final class VocabStore: ObservableObject`,
  `static let shared`, `static let stagingKey = "__staging__"`.
  - `@Published private(set) var books: [String: [VocabItem]]`
  - `items(for:) -> [VocabItem]` (sorted newest-first), `count(for:) -> Int`
  - `add(_:to:)`, `remove(itemId:from:)`, `updateNote(itemId:in:note:)`
  - `migrate(from:to:)` — moves all items from one book to another (sets `cueIndex = nil`
    when target ≠ source video, keeps `sourceTitle`), then drops the source book.
  - `deleteBook(_:)`; private `load()` / `save()` (JSONEncoder/Decoder, atomic write).
- **`SelectableTextView.swift`** — `UIViewRepresentable` over a non-editable,
  selectable, non-scrolling `UITextView` (clear bg, theme font/color). Delegate
  `textViewDidChangeSelection` → on non-empty selection calls `onSelect(substring)`.
  Caller keeps the last non-empty selection (survives the button tap clearing it).
- **`CollectSheet.swift`** — the 收藏卡. Inputs: `cue: Cue`, `entryId: String`,
  `videoTitle: String`, `onClose`. Shows selectable English + 中文 + highlight 释义
  reference + a 笔记 `TextEditor` + 「加入词汇本」 (saves selection-or-sentence) with a
  success haptic, then closes.
- **`VocabNotebookView.swift`** — list for one book. Inputs: `entryId`, `title`,
  `onJump: ((Int) -> Void)?` (nil for staging). Rows: phrase (bold) + note + sentence
  context (caption) + sourceTitle (staging only). Tap → `onJump(cueIndex)`; swipe →
  delete; note edit via a small inline editor sheet. Empty state.
- **`MigrateVocabSheet.swift`** — target picker for delete-migration. Inputs: the
  source `entryId` + count + `candidates: [(id, title)]` (other videos) + callbacks
  `onStaging`, `onPick(id)`, `onDeleteAll`. Plain List of: 暂存区, then each candidate.

### Modified
- **`Library/CueRow.swift`** — replace `onTapHighlight` with `onCollect: () -> Void`;
  move the gesture from the English line to the whole row: keep `.onTapGesture { onTapCue() }`,
  add `.onLongPressGesture { onCollect() }`. Highlight rendering (yellow underline) stays
  as display only.
- **`Library/LibraryDetailView.swift`** —
  - `@State private var collectCue: Cue?` + `@State private var showNotebook = false`.
  - `subtitleList`: pass `onCollect: { collectCue = cue }` (drop `onTapHighlight`).
  - Add a `.toolbar` (portrait only) trailing 「词汇本」button (book icon, badge =
    `VocabStore.shared.count(for: entryId)`) → `showNotebook = true`.
  - `.sheet(item: $collectCue)` → `CollectSheet(cue:, entryId:, videoTitle:)`.
  - `.sheet(isPresented: $showNotebook)` → `VocabNotebookView(entryId:, title:,
    onJump: { idx in if let c = entry.analysisJson.subtitles.first(where: { $0.index == idx }) { vm.seekTo(c) }; showNotebook = false })`.
  - Remove `.overlay { if vm.showPopup { highlightPopup } }` + the `highlightPopup` var.
    (VM's now-unused `showHighlight`/`popup*`/`showPopup` are left in place — harmless,
    avoids touching the VM blind.)
  - `Cue` must be `Identifiable` for `.sheet(item:)` — it already is (`struct Cue: Decodable, Identifiable`).
- **`Library/LibraryView.swift`** — delete flow: when `pendingDelete` is set, if
  `VocabStore.shared.count(for: entry.id) > 0`, show the migration dialog (extra buttons)
  instead of the plain confirm. `迁移到其他视频` opens `MigrateVocabSheet`. Each path does
  the VocabStore mutation **then** `vm.delete(id, token)`. Candidates = `vm.entries`
  minus the one being deleted.
- **`Me/MeView.swift`** — under 工具 (or a new 学习 section) add a NavigationLink
  「词汇暂存区」 (badge = staging count) → `VocabNotebookView(entryId: VocabStore.stagingKey,
  title: "暂存区", onJump: nil)`.

### Not changed
- `project.yml` — `sources: path: whatsub-mobile` globs new `.swift` files automatically.
- No backend, no DTO, no resources.

## Task plan (bite-sized)

1. **VocabModels + VocabStore** — model + JSON store (load/save/add/remove/updateNote/
   migrate/deleteBook/count). Self-contained; no UI.
2. **SelectableTextView** — UIViewRepresentable selectable text view + live selection callback.
3. **CollectSheet** — uses #1 + #2; saves a VocabItem.
4. **CueRow + LibraryDetailView wiring** — long-press → collectCue; toolbar 词汇本 button →
   VocabNotebookView; remove highlightPopup usage.
5. **VocabNotebookView** — list/delete/edit-note/jump.
6. **MigrateVocabSheet + LibraryView delete-migration** — dialog + picker + mutate-then-delete.
7. **MeView 暂存区 entry**.

## Out of scope (follow-ups)
- Re-filing items **out of** staging into a video (staging is view+delete for v1).
- Per-item (vs per-book) migration.
- Any cross-device sync (local only by design).

## Verification
- Compile gate = CI (`ci.yml`, iOS simulator build). **Currently blocked: GitHub Actions
  is in a major outage**; CI will run when it recovers. No XCTest target exists, so CI
  compile + manual device testing are the checks.
