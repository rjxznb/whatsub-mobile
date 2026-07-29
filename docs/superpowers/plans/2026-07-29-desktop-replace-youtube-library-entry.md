# Desktop Replace YouTube Library Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an iOS user send an existing VPN-required YouTube Library entry to the desktop, which atomically replaces its phone-generated subtitles and analysis only after self-hosted media is ready.

**Architecture:** Extend the shared import queue with an explicit `replace` mode and target Library ID. The backend validates and deduplicates replacement jobs, the desktop stages every artifact before one final replacement request, and iOS reuses the current desktop-presence, queue, and Live Activity UX.

**Tech Stack:** Swift 5.10/SwiftUI/URLSession, TypeScript/Hono/Postgres/Vitest, React/TypeScript/Zustand/Tauri/Vitest, Aliyun OSS.

## Global Constraints

- iOS 16+ and no new third-party Swift dependencies.
- Button copy is exactly `发送到桌面端下载`; do not call this an “upgrade”.
- Desktop offline means `desktopSeenSecondsAgo == nil || desktopSeenSecondsAgo > 120`; enqueue first, then show the existing yellow warning.
- Replacement jobs do not consume an additional Library item slot.
- Existing Library content must remain unchanged unless media upload, transcript, analysis, and final backend replacement all succeed.
- Existing Library ID and corpus relationships must remain unchanged.
- Preserve ordinary `mode = import` behavior and compatibility with old queue producers.
- Do not overwrite unrelated dirty-worktree files in any repository.

---

### Task 1: Backend queue schema and typed contract

**Files:**
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/schema.sql`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/types.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/db.ts`
- Test: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/import-queue-db.test.ts`

**Interfaces:**
- Produces: `ImportQueueMode = 'import' | 'replace'` and queue fields `mode`, `targetLibraryEntryId`.
- Produces: `enqueueImport(ownerEmail, url, now, options?)`, where `options = { mode?: ImportQueueMode; targetLibraryEntryId?: string }`.
- Consumed by: Tasks 2–5.

- [ ] **Step 1: Add failing DB tests for defaults, persistence, and replacement deduplication**

Add tests asserting an ordinary enqueue returns/lists `mode: 'import'` with a null target, a replacement persists its target, and two active replacements for the same owner/target return the same queue row even when URL spelling differs.

```ts
const first = await db.enqueueImport('alice@example.com', canonicalUrl, 1000, {
  mode: 'replace',
  targetLibraryEntryId: 'dQw4w9WgXcQ',
});
const second = await db.enqueueImport('alice@example.com', shortUrl, 2000, {
  mode: 'replace',
  targetLibraryEntryId: 'dQw4w9WgXcQ',
});
expect(second.id).toBe(first.id);
expect((await db.listImportQueue('alice@example.com'))[0]).toMatchObject({
  mode: 'replace',
  targetLibraryEntryId: 'dQw4w9WgXcQ',
});
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `npm test -- tests/import-queue-db.test.ts`

Expected: FAIL because the options and returned fields do not exist.

- [ ] **Step 3: Add the migration-safe schema and DB mapping**

Add schema columns with a compatibility default and invariant:

```sql
mode TEXT NOT NULL DEFAULT 'import' CHECK (mode IN ('import', 'replace')),
target_library_entry_id TEXT,
CHECK ((mode = 'import') OR (target_library_entry_id IS NOT NULL))
```

Update insert/select/mapping code. Deduplicate ordinary jobs by owner+URL as today, and replacement jobs by owner+target while status is `pending` or `processing`.

- [ ] **Step 4: Run focused and full backend tests**

Run: `npm test -- tests/import-queue-db.test.ts`

Run: `npm test`

Expected: PASS.

- [ ] **Step 5: Commit the backend queue contract**

```bash
git add schema.sql src/lib/types.ts src/lib/db.ts tests/import-queue-db.test.ts
git commit -m "feat: add replacement mode to import queue"
```

### Task 2: Backend enqueue validation and quota semantics

**Files:**
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/routes/library.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/db.ts`
- Test: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/library-routes.test.ts`
- Test: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/library-quota-db.test.ts`

**Interfaces:**
- Consumes: Task 1 queue types and DB API.
- Produces: `POST /api/library/import-queue` body `{ url, mode?, targetLibraryEntryId? }`.
- Produces: validated replacement queue items without incrementing pending-import quota usage.

- [ ] **Step 1: Write failing route tests for replacement authorization and eligibility**

Cover missing target, foreign-owner target, non-YouTube target, mismatched YouTube ID, already OSS-backed target, and a valid phone-parsed target. Assert stable 400/403/404/409 error codes and that no queue row is inserted on failure.

```ts
const res = await app.request('/api/library/import-queue', {
  method: 'POST',
  headers: authHeadersFor('alice@example.com'),
  body: JSON.stringify({
    url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    mode: 'replace',
    targetLibraryEntryId: 'dQw4w9WgXcQ',
  }),
});
expect(res.status).toBe(200);
```

- [ ] **Step 2: Write a failing quota regression test**

Fill the account to its Library item limit, enqueue a valid replacement, and assert success while an ordinary new import still returns 403 `quota_exceeded`.

- [ ] **Step 3: Run the focused tests and verify failure**

Run: `npm test -- tests/library-routes.test.ts tests/library-quota-db.test.ts`

Expected: FAIL because replacement validation and quota exclusion are absent.

- [ ] **Step 4: Implement strict enqueue validation**

Parse `mode` as `import` unless explicitly `replace`. For replace, load the target by authenticated owner, compare canonical YouTube IDs, reject `video_key IS NOT NULL`, and call Task 1's enqueue API. Never accept an owner email from request JSON.

- [ ] **Step 5: Exclude active replacement jobs from item-count quota**

Change pending-import count queries used for Library quota to count only `mode = 'import'`. Keep size/duration limits for final replacement media.

- [ ] **Step 6: Run backend tests and typecheck**

Run: `npm test`

Run: `npm run typecheck`

Expected: PASS.

- [ ] **Step 7: Commit enqueue validation**

```bash
git add src/routes/library.ts src/lib/db.ts tests/library-routes.test.ts tests/library-quota-db.test.ts
git commit -m "feat: validate desktop replacement requests"
```

### Task 3: Backend atomic replacement completion

**Files:**
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/routes/library.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/db.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/oss.ts`
- Test: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/import-queue-db.test.ts`
- Test: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/library-routes.test.ts`

**Interfaces:**
- Consumes: authenticated replacement queue ID, target ID, transcript, analysis, metadata, and already-uploaded OSS keys.
- Produces: `POST /api/library/import-queue/:id/complete-replacement`.
- Guarantees: Library update and queue `done` transition commit together.

- [ ] **Step 1: Add failing atomicity tests**

Assert foreign owners cannot complete jobs, target/YouTube mismatch is rejected, failed validation leaves both Library and queue unchanged, and success replaces transcript/analysis/media keys while preserving row ID.

```ts
expect(after.id).toBe(before.id);
expect(after.transcriptSrt).toBe(desktopSrt);
expect(after.analysisJson).toEqual(desktopAnalysis);
expect(after.videoKey).toBe(uploadedVideoKey);
expect((await db.listImportQueue(owner))[0].status).toBe('done');
```

- [ ] **Step 2: Run tests and verify failure**

Run: `npm test -- tests/import-queue-db.test.ts tests/library-routes.test.ts`

Expected: FAIL because no replacement completion transaction exists.

- [ ] **Step 3: Implement the DB transaction and route**

Lock the queue and target rows (`FOR UPDATE`), require `mode = 'replace'`, `status = 'processing'`, matching owner/target/YouTube ID, and non-null required OSS video key. Update the existing Library row and queue status in one transaction. Ensure the Library version source (`synced_at`) changes only here.

- [ ] **Step 4: Add best-effort orphan cleanup on rejected completion**

When the client reports newly uploaded keys but final attachment fails because the target disappeared or became ineligible, invoke the existing OSS deletion helper after rollback. Log cleanup failure without masking the primary API error.

- [ ] **Step 5: Run all backend verification**

Run: `npm test`

Run: `npm run typecheck`

Run: `npm run build`

Expected: PASS.

- [ ] **Step 6: Commit atomic replacement**

```bash
git add src/routes/library.ts src/lib/db.ts src/lib/oss.ts tests/import-queue-db.test.ts tests/library-routes.test.ts
git commit -m "feat: atomically replace queued library entries"
```

### Task 4: Desktop replacement-aware queue processor

**Files:**
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub/client/src/lib/api/importQueue.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub/client/src/lib/api/librarySync.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub/client/src/store/importQueue.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub/client/src/store/importQueue.test.ts`
- Modify: matching Tauri HTTP command files under `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub/client/src-tauri/src/commands/`

**Interfaces:**
- Consumes: queue fields `mode`, `targetLibraryEntryId` from Tasks 1–2.
- Produces: `completeReplacement(queueId, targetId, payload)` API wrapper.
- Guarantees: replacement jobs never call ordinary partial `syncToCloud`.

- [ ] **Step 1: Add failing processor tests**

Mock download/transcribe/analyse/upload/finalize. Verify ordinary jobs retain current behavior; replacement jobs validate generated video ID, require successful video upload, call only `completeReplacement`, and remain failed without calling completion when any stage throws.

```ts
expect(syncToCloudMock).not.toHaveBeenCalled();
expect(completeReplacementMock).toHaveBeenCalledWith(
  queue.id,
  queue.targetLibraryEntryId,
  expect.objectContaining({ transcriptSrt: freshSrt, analysisJson: freshAnalysis }),
);
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `npm test -- src/store/importQueue.test.ts`

Expected: FAIL because queue mode and replacement completion are not handled.

- [ ] **Step 3: Extend TypeScript and Rust queue DTOs without breaking defaults**

Decode missing `mode` as `import`; expose `targetLibraryEntryId?: string`. Ensure a desktop build that lacks replacement support cannot claim `replace` rows by adding a supported-mode parameter/filter to pending list or claim.

- [ ] **Step 4: Implement staged replacement processing**

Branch after claim. Run the existing media pipeline, require generated YouTube ID equals target, require all required OSS uploads, then call the final endpoint. On any error set queue status `failed` with the existing concise error text; do not call ordinary sync.

- [ ] **Step 5: Run desktop tests and builds**

Run: `npm test`

Run: `npm run typecheck`

Run: `npm run build`

Run from `src-tauri`: `cargo check`

Expected: PASS.

- [ ] **Step 6: Commit desktop support**

```bash
git add src/lib/api/importQueue.ts src/lib/api/librarySync.ts src/store/importQueue.ts src/store/importQueue.test.ts src-tauri/src/commands
git commit -m "feat: process library replacement jobs on desktop"
```

### Task 5: iOS request contract and Library detail action

**Files:**
- Modify: `whatsub-mobile/Networking/WhatsubAPI.swift`
- Modify: `whatsub-mobile/Networking/DTOs.swift`
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Modify: `whatsub-mobile/Library/LibraryDetailViewModel.swift`
- Test: `whatsub-mobileTests/LibraryDesktopReplacementTests.swift`

**Interfaces:**
- Consumes: Task 2 enqueue contract and existing `desktopSeenSecondsAgo` semantics.
- Produces: `enqueueReplacement(url:targetLibraryEntryId:token:) async throws -> Int?`.
- Produces: detail UI state `idle`, `sending`, `queued(desktopOffline:)`, `failed(String)`.

- [ ] **Step 1: Add failing eligibility and presence tests**

Extract pure helpers so XCTest can assert that the action appears only for YouTube entries with no `videoUrl`, and that nil/121 seconds are offline while 0/120 seconds are online.

```swift
XCTAssertTrue(entry.needsDesktopDownload)
XCTAssertTrue(DesktopPresence.isOffline(secondsAgo: nil))
XCTAssertTrue(DesktopPresence.isOffline(secondsAgo: 121))
XCTAssertFalse(DesktopPresence.isOffline(secondsAgo: 120))
```

- [ ] **Step 2: Run the focused XCTest and verify failure**

Run in CI/macOS: `xcodebuild test -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro' -only-testing:whatsub-mobileTests/LibraryDesktopReplacementTests`

Expected: FAIL because helpers and request method do not exist.

- [ ] **Step 3: Add request and queue DTO fields**

Encode exactly:

```swift
[
  "url": canonicalYouTubeURL,
  "mode": "replace",
  "targetLibraryEntryId": entry.id
]
```

Decode queue `mode` and `targetLibraryEntryId` as optional/default-compatible fields. Reuse the enqueue response's `desktopSeenSecondsAgo`.

- [ ] **Step 4: Add “发送到桌面端下载” to eligible detail views**

Show explanatory confirmation copy, a sending state, and a queued result. Reuse the exact 120-second rule and yellow offline copy from ImportView. Start/refresh the existing Live Activity with the current account email. Do not show the action for OSS-backed or non-YouTube entries.

- [ ] **Step 5: Surface existing active replacement state**

Use the queue list response on detail load/refresh to detect a pending or processing replacement for this target. Disable duplicate sending and show `已发送，等待桌面端` or `桌面端处理中`.

- [ ] **Step 6: Refresh after completion without polling aggressively**

Use existing foreground refresh, pull-to-refresh, queue deep link, and Library version validation. Do not add a tight detail polling loop. Once `videoUrl` appears, hide the action and render the native player.

- [ ] **Step 7: Run iOS verification**

Run on macOS/CI: `xcodegen generate`

Run: `xcodebuild test -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15 Pro'`

Run: the existing CI simulator screenshot workflow.

Expected: build and tests PASS; screenshot shows no regression on launch.

- [ ] **Step 8: Commit iOS support**

```bash
git add whatsub-mobile/Networking/WhatsubAPI.swift whatsub-mobile/Networking/DTOs.swift whatsub-mobile/Library/LibraryDetailView.swift whatsub-mobile/Library/LibraryDetailViewModel.swift whatsub-mobileTests/LibraryDesktopReplacementTests.swift
git commit -m "feat: send existing YouTube entries to desktop"
```

### Task 6: Cross-client compatibility, deployment, and end-to-end verification

**Files:**
- Modify: `AGENTS.md` in each changed repository with the shipped behavior and deployment order.
- Modify: deployment/migration files only if the backend repository's established process requires them.

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: deployed backend contract, compatible desktop release, and iOS build.

- [ ] **Step 1: Verify old-client compatibility before deployment**

Run backend tests with ordinary queue payloads containing only `{ url }`. Verify returned extra fields do not break current iOS decoding and that the server does not offer `replace` jobs to unsupported desktop pollers.

- [ ] **Step 2: Deploy in safe order**

Deploy backend schema/API first, then release the replacement-aware desktop client, then ship the iOS action. Do not expose the iOS button before a production desktop build can claim and complete replacement jobs.

- [ ] **Step 3: Exercise the success path with a disposable test entry**

Create a phone-parsed YouTube entry, send it while desktop is online, and verify: one queue row, processing status, fresh transcript/analysis, OSS player, unchanged Library ID, and preserved corpus phrases.

- [ ] **Step 4: Exercise offline and failure paths**

With desktop closed for more than 120 seconds, enqueue and verify the yellow warning; then open desktop and verify processing begins. Separately force download, analysis, upload, and finalization failures and compare the Library row before/after to prove it is unchanged.

- [ ] **Step 5: Exercise quota and duplicate paths**

At the account's item limit, verify replacement succeeds while new import remains blocked. Tap repeatedly and verify only one active replacement queue row exists.

- [ ] **Step 6: Update architecture notes and run final verification**

Run backend: `npm test && npm run typecheck && npm run build`.

Run desktop: `npm test && npm run typecheck && npm run build`, plus `cargo check`.

Run iOS CI and TestFlight workflows and confirm completion before reporting deployment.

- [ ] **Step 7: Commit documentation separately in each repository**

```bash
git add AGENTS.md
git commit -m "docs: document desktop library replacement flow"
```
