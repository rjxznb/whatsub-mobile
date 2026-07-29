# Desktop Replacement Toolbar Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the large Library detail replacement card with a compact navigation-bar icon that opens the same workflow in a sheet.

**Architecture:** Keep all queue, duration-preflight, desktop-presence, confirmation, and error state in the existing `LibraryDetailViewModel`. Change only `LibraryDetailView`: a conditional toolbar item owns presentation of a compact sheet, while the former inline card is removed from the portrait content stack.

**Tech Stack:** Swift 5.10, SwiftUI, iOS 16+, XCTest, XcodeGen.

## Global Constraints

- Show the toolbar icon only for entries where `needsDesktopDownload == true`.
- Do not change backend APIs, queue semantics, duration-limit behavior, or polling behavior.
- Preserve pending, processing, sending, failed, online, and offline UI states.
- The navigation bar remains hidden in landscape.

---

### Task 1: Move desktop replacement UI into the toolbar sheet

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift:39-180,354-490`
- Test: `whatsub-mobileTests/LibraryDesktopReplacementTests.swift`

**Interfaces:**
- Consumes: `LibraryEntryDetail.needsDesktopDownload`, `LibraryDetailViewModel.desktopReplacementState`, `activeReplacementStatus`, and `enqueueReplacement(maxVideoSeconds:token:email:)`.
- Produces: `showDesktopReplacementSheet: Bool`, a conditional toolbar button, status-overlay icon, and `desktopReplacementSheet`.

- [ ] **Step 1: Add presentation state and a conditional toolbar entry**

Add `@State private var showDesktopReplacementSheet = false`. In the existing toolbar configuration, render a trailing button only when `vm.entry?.needsDesktopDownload == true`; use `desktopcomputer` as the base symbol, a small `ProgressView` for sending/pending/processing, and a red `exclamationmark.circle.fill` overlay for failed state.

- [ ] **Step 2: Verify the source no longer places the card inline**

Run:

```powershell
rg -n "desktopReplacementCard" whatsub-mobile/Library/LibraryDetailView.swift
```

Expected before implementation: one portrait call site and one declaration. Expected after implementation: no matches.

- [ ] **Step 3: Move the existing card content into a sheet**

Attach `.sheet(isPresented: $showDesktopReplacementSheet)` to the root view. Build a compact `NavigationStack` sheet containing the existing explanation, status text, offline warning, failure message, and primary send button. Add a top-right “完成” button. Keep `confirmDesktopReplacement` as the final confirmation before calling the existing ViewModel method.

- [ ] **Step 4: Remove the inline card and preserve state behavior**

Delete the portrait `desktopReplacementCard` call and its card-only padding/background wrapper. Keep `activeReplacementText`, `replacementActionDisabled`, and `desktopOfflineWarning`, adapting them only as needed by the sheet.

- [ ] **Step 5: Run focused and full verification**

Run on macOS CI through the existing workflow:

```bash
xcodegen generate
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -sdk iphonesimulator build
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -sdk iphonesimulator test
```

Expected: build succeeds and all XCTest cases, including `LibraryDesktopReplacementTests`, pass.

- [ ] **Step 6: Commit**

```bash
git add whatsub-mobile/Library/LibraryDetailView.swift docs/superpowers/plans/2026-07-29-desktop-replacement-toolbar-entry.md
git commit -m "ui: compact desktop replacement entry"
```
