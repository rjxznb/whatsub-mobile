# Progressive Mobile Library Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a captioned YouTube video appear in Library immediately, open its playable English transcript automatically, and reveal server-analyzed bilingual cues in durable batches while managed analysis continues in the background.

**Architecture:** The backend atomically creates an English-only provisional `library_entries` row with the managed job, keeps completed 50-cue results in `mobile_analysis_batches`, and exposes cursor-based incremental reads. iOS renders the provisional transcript immediately, overlays only committed batches, and reloads the final Library payload once finalization completes; the Library list overlays lightweight job status without invalidating its cached list per batch.

**Tech Stack:** Swift 5.10, SwiftUI, URLSession, XCTest, Hono, TypeScript 5.6, PostgreSQL, Vitest.

## Global Constraints

- Mobile implementation starts from `origin/main` commit `0654892` or newer so the released background-analysis diagnostics remain present.
- Backend implementation starts from `codex/mobile-background-analysis-backend` commit `aabd0a2` or newer.
- iOS minimum remains iOS 16; no third-party Swift package is added.
- Managed model requests remain at most 50 cues and retain existing per-owner/global queue limits, leases, retries, quota accounting, and APNs publication.
- BYOK remains client-only and unlimited-length; leaving the app pauses it instead of moving it to managed server capacity.
- Only server-completed, revalidated batches may appear as progressive translations.
- `library_entries.synced_at` changes on provisional creation and final completion, never once per cue batch.
- Failed or user-cancelled analysis keeps the English-only Library entry and may be resumed against the same job and entry ID.
- Deleting an active provisional entry cancels its job and stale workers cannot recreate it.
- Backend must be deployed before releasing the compatible iOS client.

---

## File Structure

### Backend repository: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license`

- Modify `src/lib/mobileAnalysis.ts`: build the deterministic provisional English analysis payload.
- Modify `src/lib/db.ts`: atomically create provisional entries, read validated completed batches, resume terminal jobs safely, and cancel jobs during Library deletion.
- Modify `src/lib/types.ts`: define the incremental result page and completed-batch wire shapes.
- Modify `src/routes/mobileAnalysis.ts`: expose cursor-based results and allow explicit safe resume.
- Modify `src/routes/library.ts`: use the transactional delete-and-cancel operation.
- Modify `tests/mobile-analysis-db.test.ts`: database lifecycle, version, resume, delete, and stale-finalizer coverage.
- Modify `tests/mobile-analysis-routes.test.ts`: ownership, cursor, response, and resume route coverage.
- Modify `tests/mobile-analysis-worker.test.ts`: finalization preserves the same provisional row.
- Modify `tests/library-routes.test.ts`: deleting an active provisional entry cancels analysis.

### iOS repository: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile`

- Modify `whatsub-mobile/Import/ManagedAnalysisModels.swift`: incremental DTOs, status helpers, and client protocol.
- Modify `whatsub-mobile/Import/ManagedAnalysisClient.swift`: fetch cursor-based incremental pages.
- Modify `whatsub-mobile/Networking/WhatsubAPI.swift`: forward the new managed result call.
- Create `whatsub-mobile/Library/ProgressiveAnalysisOverlay.swift`: pure validated cue merge and polling-delay policy.
- Modify `whatsub-mobile/Library/LibraryDetailViewModel.swift`: discover the entry's job, poll deltas, merge cues, resume, and reload final detail.
- Modify `whatsub-mobile/Library/LibraryDetailView.swift`: progress banner, waiting rows, resume action, and progressive cue rendering.
- Modify `whatsub-mobile/Import/ImportView.swift`: automatically dismiss and route when creation returns the provisional entry ID.
- Modify `whatsub-mobile/Library/LibraryViewModel.swift`: lightweight managed-job status overlay independent of Library cache.
- Modify `whatsub-mobile/Library/LibraryView.swift`: visible-only status polling and card badges.
- Create `whatsub-mobileTests/ProgressiveAnalysisOverlayTests.swift`: authoritative-field and merge invariants.
- Create `whatsub-mobileTests/LibraryManagedAnalysisTests.swift`: detail polling/finalization and list status behavior.
- Modify `whatsub-mobileTests/ManagedAnalysisClientTests.swift`: incremental endpoint request/decoding.
- Modify `whatsub-mobileTests/ImportManagedAnalysisTests.swift`: immediate non-null result entry behavior.

---

### Task 1: Atomically create the provisional English Library entry

**Files:**
- Modify: `whatsub-license/src/lib/mobileAnalysis.ts`
- Modify: `whatsub-license/src/lib/db.ts`
- Test: `whatsub-license/tests/mobile-analysis-db.test.ts`

**Interfaces:**
- Consumes: `CreateMobileAnalysisJobInput.cues`, `transcriptSrt`, and existing `library_entries` schema.
- Produces: `buildProvisionalLibraryAnalysis(cues: readonly MobileAnalysisCue[]): { subtitles: ProvisionalCue[]; keyPhrases: [] }`; newly created jobs have `resultEntryId === job.id`.

- [ ] **Step 1: Write failing database tests**

Add tests that assert job creation immediately returns its ID as `resultEntryId`, `getLibraryEntry(job.id, owner)` returns all authoritative English cues with empty generated fields, and an injected batch-insert failure rolls back both rows:

```ts
const job = await db.createMobileAnalysisJob(jobInput({
  ownerEmail: 'progressive@example.com',
  cues: [{ index: 0, time: 1.25, endTime: 2.5, text: 'Keep this text.' }],
}));
expect(job.resultEntryId).toBe(job.id);
expect((await db.getLibraryEntry(job.id, 'progressive@example.com'))?.analysisJson).toEqual({
  subtitles: [{
    index: 0, time: 1.25, endTime: 2.5, text: 'Keep this text.',
    translation: '', isKeyPoint: false,
    highlightWords: [], keyNotes: {}, highlightTranslations: {},
  }],
  keyPhrases: [],
});
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `npm test -- tests/mobile-analysis-db.test.ts`

Expected: FAIL because creation leaves `result_entry_id` null and no Library row exists.

- [ ] **Step 3: Add the deterministic provisional payload builder**

Implement a pure builder whose output takes text/timestamps/index only from submitted cues:

```ts
export function buildProvisionalLibraryAnalysis(cues: readonly MobileAnalysisCue[]) {
  return {
    subtitles: cues.map((cue) => ({
      index: cue.index,
      time: cue.time,
      endTime: cue.endTime,
      text: cue.text,
      translation: '',
      isKeyPoint: false,
      highlightWords: [],
      keyNotes: {},
      highlightTranslations: {},
    })),
    keyPhrases: [],
  };
}
```

- [ ] **Step 4: Insert the provisional row inside `createMobileAnalysisJob`'s transaction**

After all batch rows are inserted, insert `library_entries` with `id = job.id`, accepted request metadata, transcript, thumbnail, and the provisional payload; then update the job's `result_entry_id`. Preserve the existing same-owner conflict fence and throw `MobileAnalysisJobCreationError('library_id_collision')` before commit for another-owner collisions.

- [ ] **Step 5: Run database tests**

Run: `npm test -- tests/mobile-analysis-db.test.ts`

Expected: PASS, including rollback and idempotency tests.

- [ ] **Step 6: Commit backend creation changes**

```bash
git add src/lib/mobileAnalysis.ts src/lib/db.ts tests/mobile-analysis-db.test.ts
git commit -m "feat: create provisional library entries for mobile analysis"
```

### Task 2: Expose validated cursor-based completed batches

**Files:**
- Modify: `whatsub-license/src/lib/types.ts`
- Modify: `whatsub-license/src/lib/db.ts`
- Modify: `whatsub-license/src/routes/mobileAnalysis.ts`
- Test: `whatsub-license/tests/mobile-analysis-db.test.ts`
- Test: `whatsub-license/tests/mobile-analysis-routes.test.ts`

**Interfaces:**
- Consumes: completed `mobile_analysis_batches` rows and `validatePersistedCueBatch`.
- Produces: `Database.getMobileAnalysisResultsPage(jobId, ownerEmail, afterBatch)` and `GET /api/library/mobile-analysis/jobs/:id/results?afterBatch=N`.

- [ ] **Step 1: Write failing DB and route tests**

Seed three cue batches, complete batches 0 and 1, leave batch 2 unfinished, and assert `afterBatch=0` returns only batch 1. Assert another owner receives 404, malformed cursors receive 400, and persisted corrupt cue JSON fails closed without returning model content.

```ts
expect(await jsonOf(ownerRequest(`/jobs/${job.id}/results?afterBatch=0`))).toMatchObject({
  jobId: job.id,
  entryId: job.id,
  completedCues: 100,
  totalCues: 120,
  nextBatchCursor: 1,
  batches: [{ batchIndex: 1 }],
});
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `npm test -- tests/mobile-analysis-db.test.ts tests/mobile-analysis-routes.test.ts`

Expected: FAIL with no results method/route.

- [ ] **Step 3: Define exact result types**

```ts
export interface MobileAnalysisResultCue {
  index: number;
  time: number;
  endTime: number;
  text: string;
  translation: string;
  isKeyPoint: boolean;
  highlightWords: string[];
  keyNotes: Record<string, string>;
  highlightTranslations: Record<string, string>;
}

export interface MobileAnalysisCompletedBatch {
  batchIndex: number;
  subtitles: MobileAnalysisResultCue[];
}

export interface MobileAnalysisResultsPage {
  jobId: string;
  entryId: string;
  status: MobileAnalysisJobStatus;
  completedCues: number;
  totalCues: number;
  nextBatchCursor: number;
  batches: MobileAnalysisCompletedBatch[];
  errorCode: string | null;
}
```

- [ ] **Step 4: Implement the owner-scoped DB read**

Read the job and completed cue batches in order, select only `batch_index > afterBatch`, slice each batch's authoritative submitted cues, call `validatePersistedCueBatch`, and return public-safe status/error data. Calculate `completedCues` from completed cue ranges rather than `completed_batches * 50` so the final short batch is exact.

- [ ] **Step 5: Implement and throttle the route**

Parse `afterBatch` as an integer in `[-1, totalBatches - 1]`, require the existing session middleware, return 404 for non-owners, and use the existing request-rate-limit pattern to cap this lightweight endpoint per session/job. Do not expose prompts, raw malformed JSON, or internal error strings.

- [ ] **Step 6: Run focused tests**

Run: `npm test -- tests/mobile-analysis-db.test.ts tests/mobile-analysis-routes.test.ts`

Expected: PASS.

- [ ] **Step 7: Commit incremental endpoint changes**

```bash
git add src/lib/types.ts src/lib/db.ts src/routes/mobileAnalysis.ts tests/mobile-analysis-db.test.ts tests/mobile-analysis-routes.test.ts
git commit -m "feat: expose incremental mobile analysis batches"
```

### Task 3: Preserve one entry through completion, cancellation, resume, and deletion

**Files:**
- Modify: `whatsub-license/src/lib/db.ts`
- Modify: `whatsub-license/src/routes/mobileAnalysis.ts`
- Modify: `whatsub-license/src/routes/library.ts`
- Test: `whatsub-license/tests/mobile-analysis-db.test.ts`
- Test: `whatsub-license/tests/mobile-analysis-routes.test.ts`
- Test: `whatsub-license/tests/mobile-analysis-worker.test.ts`
- Test: `whatsub-license/tests/library-routes.test.ts`

**Interfaces:**
- Consumes: provisional `result_entry_id`, existing claim lease fences, and Library deletion.
- Produces: `resumeMobileAnalysisJob` supports paused/failed/user-cancelled jobs only when their Library row still exists; `deleteLibraryEntry` cancels matching active analysis transactionally.

- [ ] **Step 1: Update failing lifecycle tests**

Assert these invariants:

```ts
expect(await db.finalizeMobileAnalysisJob(claim, finalAnalysis)).toBe('completed');
expect((await db.getLibraryEntry(job.id, owner))?.id).toBe(job.id);
expect(await db.getLibraryVersion(owner)).not.toBe(versionAfterCreation);

await db.cancelMobileAnalysisJob(job.id, owner, now);
expect(await db.getLibraryEntry(job.id, owner)).toBeDefined();
expect(await db.resumeMobileAnalysisJob(job.id, owner, now + 1)).toBe(true);
```

Also assert each completed cue batch leaves the Library version unchanged, deletion marks the job cancelled with `error_code = 'library_entry_deleted'`, resume then returns false, and an already-held finalization claim returns `lease_lost` without recreating the row.

- [ ] **Step 2: Run lifecycle tests and verify failure**

Run: `npm test -- tests/mobile-analysis-db.test.ts tests/mobile-analysis-routes.test.ts tests/mobile-analysis-worker.test.ts tests/library-routes.test.ts`

Expected: FAIL because finalization assumes no existing provisional row, terminal resume is rejected, and deletion is not coupled to job cancellation.

- [ ] **Step 3: Make finalization replace the provisional payload**

Keep the existing owner collision and lease checks. Update the same row's final `analysis_json`, transcript/metadata, thumbnail, and `synced_at`; do not create a second entry. Mark the job completed in the same transaction.

- [ ] **Step 4: Implement explicit safe resume**

Within one transaction, lock the job and its Library row. Permit `paused_quota`, `failed`, and user `cancelled` states when `result_entry_id` still points to an owned row. Set status to `queued`, clear cancellation/error/lease state, reset `attempts = 0` only on unfinished batches, and preserve completed batches and token usage. Reject completed jobs and deletion-cancelled jobs.

- [ ] **Step 5: Couple Library deletion to managed cancellation**

In the Library-delete transaction, lock the owned entry and matching job, set any non-completed job to cancelled with `cancel_requested = TRUE`, `error_code = 'library_entry_deleted'`, clear its lease, then delete the Library row and return its OSS keys. Existing object cleanup remains outside the transaction after commit.

- [ ] **Step 6: Run lifecycle tests**

Run: `npm test -- tests/mobile-analysis-db.test.ts tests/mobile-analysis-routes.test.ts tests/mobile-analysis-worker.test.ts tests/library-routes.test.ts`

Expected: PASS.

- [ ] **Step 7: Commit lifecycle changes**

```bash
git add src/lib/db.ts src/routes/mobileAnalysis.ts src/routes/library.ts tests/mobile-analysis-db.test.ts tests/mobile-analysis-routes.test.ts tests/mobile-analysis-worker.test.ts tests/library-routes.test.ts
git commit -m "fix: preserve progressive library analysis lifecycle"
```

### Task 4: Add iOS incremental DTOs and client request

**Files:**
- Modify: `whatsub-mobile/Import/ManagedAnalysisModels.swift`
- Modify: `whatsub-mobile/Import/ManagedAnalysisClient.swift`
- Modify: `whatsub-mobile/Networking/WhatsubAPI.swift`
- Modify: `whatsub-mobileTests/ManagedAnalysisClientTests.swift`

**Interfaces:**
- Consumes: backend `MobileAnalysisResultsPage` JSON.
- Produces: `ManagedAnalysisClientProtocol.results(id:afterBatch:token:) async throws -> ManagedAnalysisResultsPage`.

- [ ] **Step 1: Write failing decoding and URL tests**

```swift
let page = try JSONDecoder().decode(ManagedAnalysisResultsPage.self, from: Data(json.utf8))
XCTAssertEqual(page.nextBatchCursor, 1)
XCTAssertEqual(page.batches.flatMap(\.subtitles).count, 50)

_ = try await client.results(id: "job/unsafe", afterBatch: 2, token: "token")
XCTAssertEqual(URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems,
               [URLQueryItem(name: "afterBatch", value: "2")])
```

- [ ] **Step 2: Run CI unit tests and verify failure**

Run on macOS: `xcodegen generate && xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test`

Expected: compile failure because the new DTO and protocol method do not exist.

- [ ] **Step 3: Add exact Swift DTOs**

```swift
struct ManagedAnalysisCompletedBatch: Decodable {
    let batchIndex: Int
    let subtitles: [Cue]
}

struct ManagedAnalysisResultsPage: Decodable {
    let jobId: String
    let entryId: String
    let status: ManagedAnalysisJobStatus
    let completedCues: Int
    let totalCues: Int
    let nextBatchCursor: Int
    let batches: [ManagedAnalysisCompletedBatch]
    let errorCode: ManagedAnalysisFailureCode?
}
```

- [ ] **Step 4: Implement query-safe client construction**

Extend endpoint construction to accept `[URLQueryItem]` through `URLComponents`, then implement `results` as GET `jobs/{encoded id}/results?afterBatch=N`. Preserve current cancellation and sanitized error mapping.

- [ ] **Step 5: Run focused iOS tests**

Run the Task 4 simulator test command.

Expected: PASS.

- [ ] **Step 6: Commit iOS transport changes**

```bash
git add whatsub-mobile/Import/ManagedAnalysisModels.swift whatsub-mobile/Import/ManagedAnalysisClient.swift whatsub-mobile/Networking/WhatsubAPI.swift whatsub-mobileTests/ManagedAnalysisClientTests.swift
git commit -m "feat: fetch incremental mobile analysis results"
```

### Task 5: Build the authoritative progressive cue overlay

**Files:**
- Create: `whatsub-mobile/Library/ProgressiveAnalysisOverlay.swift`
- Create: `whatsub-mobileTests/ProgressiveAnalysisOverlayTests.swift`

**Interfaces:**
- Consumes: baseline `[Cue]` and completed `ManagedAnalysisCompletedBatch` values.
- Produces: `ProgressiveAnalysisOverlay.merge(_:)`, `displayedCues(from:)`, `resolvedIndexes`, and `ManagedAnalysisPollPolicy.delay(status:failureCount:) -> TimeInterval?`.

- [ ] **Step 1: Write failing pure unit tests**

Test that generated translation/highlight fields are accepted only for an existing matching index, while baseline index/time/endTime/text always win. Test duplicate/out-of-range results are ignored, repeated batches are idempotent, and error delay backs off to a fixed maximum.

```swift
XCTAssertEqual(displayed[0].text, "Authoritative English")
XCTAssertEqual(displayed[0].time, 1.0)
XCTAssertEqual(displayed[0].translation, "生成的中文")
XCTAssertEqual(overlay.resolvedIndexes, Set([0]))
```

- [ ] **Step 2: Run tests and verify compile failure**

Run the Task 4 simulator test command.

Expected: compile failure because `ProgressiveAnalysisOverlay` is missing.

- [ ] **Step 3: Implement the focused merge type**

Store generated cues by baseline index. When producing display cues, copy only `translation`, `isKeyPoint`, `highlightWords`, `keyNotes`, and `highlightTranslations` from the generated cue onto the baseline value. Accept a generated cue only when its index exists, translation is non-empty, and its authoritative fields equal the baseline within exact text and 1 ms timestamp tolerance.

- [ ] **Step 4: Implement deterministic polling policy**

Use 2 seconds for running, 5 seconds for queued, `nil` for paused/terminal states, and exponential network-error delays `2, 4, 8, 15` seconds capped at 15. Apply bounded random jitter at the caller so policy tests remain deterministic.

- [ ] **Step 5: Run pure tests**

Run the Task 4 simulator test command.

Expected: PASS.

- [ ] **Step 6: Commit overlay changes**

```bash
git add whatsub-mobile/Library/ProgressiveAnalysisOverlay.swift whatsub-mobileTests/ProgressiveAnalysisOverlayTests.swift
git commit -m "feat: merge progressive analysis cues safely"
```

### Task 6: Drive detail progress, recovery, and final reload

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailViewModel.swift`
- Create: `whatsub-mobileTests/LibraryManagedAnalysisTests.swift`

**Interfaces:**
- Consumes: `LibraryDesktopReplacementAPI.libraryEntry`, `ManagedAnalysisClientProtocol.jobs/results/resume`, and `ProgressiveAnalysisOverlay`.
- Produces: `displayedCues`, `managedJob`, `managedProgressText`, `isWaitingForAI(_:)`, `startProgressPolling`, `stopProgressPolling`, and `resumeManagedAnalysis`.

- [ ] **Step 1: Write failing view-model tests with an actor spy**

Cover initial English rendering, job discovery by `resultEntryId == entry.id`, cursor advancement, one-time merge, error retention/backoff, terminal stop, completion detail reload, failure/cancellation preservation, resume, and task cancellation on stop.

```swift
await viewModel.load(id: "entry-1", token: "token")
XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["", ""])
await viewModel.pollManagedAnalysisOnce(token: "token")
XCTAssertEqual(viewModel.displayedCues[0].translation, "你好")
XCTAssertEqual(spy.requestedCursors, [-1])
```

- [ ] **Step 2: Run tests and verify failure**

Run the Task 4 simulator test command.

Expected: compile failure because progressive view-model state is absent.

- [ ] **Step 3: Add injected managed API and progressive state**

Inject `ManagedAnalysisClientProtocol` beside the existing replacement API. Keep a baseline entry, overlay, cursor initialized to `-1`, polling `Task`, and failure count. Publish display cues and job state on `MainActor`.

- [ ] **Step 4: Implement discovery and delta polling**

After first-paint detail load, fetch managed jobs best-effort and choose the newest job whose `resultEntryId` equals the entry ID. Fetch only pages after the cursor. Merge committed batches, update status/progress, and stop on failed/cancelled/completed. On completed, call the normal detail endpoint once and clear the overlay only after the final payload succeeds.

- [ ] **Step 5: Implement explicit resume**

Call `resume(id:token:)`, retain visible English and completed translations, reset only polling failure state, and restart polling with the returned queued job.

- [ ] **Step 6: Run view-model tests**

Run the Task 4 simulator test command.

Expected: PASS.

- [ ] **Step 7: Commit detail state changes**

```bash
git add whatsub-mobile/Library/LibraryDetailViewModel.swift whatsub-mobileTests/LibraryManagedAnalysisTests.swift
git commit -m "feat: stream durable analysis progress into library detail"
```

### Task 7: Present immediate English learning and progressive bilingual rows

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Modify: `whatsub-mobile/Library/CueRow.swift`
- Modify: `whatsub-mobileTests/LibraryManagedAnalysisTests.swift`

**Interfaces:**
- Consumes: Task 6 view-model presentation properties.
- Produces: compact progress banner, unresolved-row presentation, and resume controls.

- [ ] **Step 1: Add failing presentation tests**

Extract/test pure presentation values so queued/running/failed/cancelled/completed states produce these exact user-facing meanings: `等待服务器`, `AI 解析中 · 150/620`, `仅英文 · AI 解析失败`, `仅英文 · 已取消`, and no banner after completion.

- [ ] **Step 2: Run tests and verify failure**

Run the Task 4 simulator test command.

Expected: FAIL because progressive presentation helpers are absent.

- [ ] **Step 3: Render progress without disrupting playback**

Place a compact banner between player and content picker. Running shows `ProgressView(value:)`; failed/cancelled/paused shows a `继续 AI 解析` button. Keep YouTube playback and all English rows interactive while analysis is incomplete.

- [ ] **Step 4: Render `displayedCues` everywhere learning depends on cues**

Use `vm.displayedCues` for subtitle rows, current-cue lookup, cloze cue pool, and collection/shadow actions. Disable subtitle editing whenever a related managed job exists and is not completed—including failed/cancelled jobs that can later resume—to avoid user edits racing the final server replacement.

- [ ] **Step 5: Add unresolved-row styling**

Extend `CueRow` with `isAwaitingAnalysis: Bool = false`. When true, render English normally and a subdued `等待 AI` caption where Chinese would appear; do not use a spinner per row or animate row height repeatedly.

- [ ] **Step 6: Run iOS tests**

Run the Task 4 simulator test command.

Expected: PASS.

- [ ] **Step 7: Commit progressive detail UI**

```bash
git add whatsub-mobile/Library/LibraryDetailView.swift whatsub-mobile/Library/CueRow.swift whatsub-mobileTests/LibraryManagedAnalysisTests.swift
git commit -m "feat: show progressive bilingual subtitles in library"
```

### Task 8: Route directly into the provisional entry after submission

**Files:**
- Modify: `whatsub-mobile/Import/ImportView.swift`
- Modify: `whatsub-mobileTests/ImportManagedAnalysisTests.swift`
- Modify: `whatsub-mobileTests/ManagedAnalysisPresentationTests.swift`

**Interfaces:**
- Consumes: managed creation response with non-null `resultEntryId` and existing `AppState.pendingLibraryEntryID`.
- Produces: one automatic dismiss/navigation event per submitted job.

- [ ] **Step 1: Write failing route-decision tests**

Add a pure helper that returns an entry ID only for queued/running/paused/failed/cancelled managed states with a non-empty `resultEntryId`, and never fires twice for the same job ID.

```swift
XCTAssertEqual(ManagedImportRoute.destination(for: queuedJob), "entry-123")
XCTAssertNil(ManagedImportRoute.destination(for: jobWithoutEntry))
```

- [ ] **Step 2: Run tests and verify failure**

Run the Task 4 simulator test command.

Expected: compile failure because `ManagedImportRoute` does not exist.

- [ ] **Step 3: Implement automatic handoff in `ImportView`**

Observe the published import state. On the first managed job carrying an entry ID, seed the existing Live Activity as today, assign `appState.pendingLibraryEntryID`, and dismiss the import sheet. Preserve policy/error screens when no entry was created.

- [ ] **Step 4: Run import tests**

Run the Task 4 simulator test command.

Expected: PASS.

- [ ] **Step 5: Commit routing changes**

```bash
git add whatsub-mobile/Import/ImportView.swift whatsub-mobileTests/ImportManagedAnalysisTests.swift whatsub-mobileTests/ManagedAnalysisPresentationTests.swift
git commit -m "feat: open provisional library video after caption import"
```

### Task 9: Overlay managed progress on Library cards without cache churn

**Files:**
- Modify: `whatsub-mobile/Library/LibraryViewModel.swift`
- Modify: `whatsub-mobile/Library/LibraryView.swift`
- Modify: `whatsub-mobileTests/LibraryManagedAnalysisTests.swift`

**Interfaces:**
- Consumes: cached/full `LibraryListItem` rows and `ManagedAnalysisClientProtocol.jobs`.
- Produces: `managedJobByEntryID`, `refreshManagedJobs`, and visible-only polling.

- [ ] **Step 1: Write failing list overlay tests**

Verify the newest job per non-null `resultEntryId` wins, completed jobs produce no badge, failed/cancelled cards stay present, and refreshing jobs does not call `LibraryCache.store` or `/api/library/list`.

- [ ] **Step 2: Run tests and verify failure**

Run the Task 4 simulator test command.

Expected: compile failure because list progress state is absent.

- [ ] **Step 3: Add independent job-state refresh**

Inject the managed API into `LibraryViewModel`, build `[entryID: ManagedAnalysisJob]`, and expose a best-effort refresh that never clears Library entries or cache on failure.

- [ ] **Step 4: Poll only while the list is visible and active jobs exist**

Start a cancellable task on list appearance, refresh every 5 seconds while any queued/running job exists, and stop on disappearance or when all remaining jobs are paused/terminal. Trigger one Library reload when `pendingLibraryEntryID` arrives so the new provisional card is cached, but navigate immediately without waiting for that reload.

- [ ] **Step 5: Render compact card state**

Pass the matching job into `LibraryRow` and show one caption under duration/VPN: `AI 解析中 · N/M`, `等待服务器`, or `仅英文 · 解析未完成`. Do not enlarge the thumbnail or add a second action button to the card.

- [ ] **Step 6: Run list tests**

Run the Task 4 simulator test command.

Expected: PASS.

- [ ] **Step 7: Commit Library status overlay**

```bash
git add whatsub-mobile/Library/LibraryViewModel.swift whatsub-mobile/Library/LibraryView.swift whatsub-mobileTests/LibraryManagedAnalysisTests.swift
git commit -m "feat: show managed analysis progress on library cards"
```

### Task 10: Full verification and compatibility rollout checks

**Files:**
- Modify: `whatsub-license/tests/mobile-analysis-postgres.integration.test.ts`

**Interfaces:**
- Consumes: all previous tasks.
- Produces: a backend release safe for old iOS clients and a new iOS build safe against the deployed backend.

- [ ] **Step 1: Run all backend tests and type checks**

```bash
npm test
npm run typecheck
npm run build
```

Expected: all commands exit 0.

- [ ] **Step 2: Run PostgreSQL integration coverage**

Against a disposable loopback PostgreSQL database whose name matches `whatsub_*_test`, run:

```powershell
$env:MOBILE_ANALYSIS_TEST_POSTGRES='1'
$env:MOBILE_ANALYSIS_TEST_DATABASE_URL='postgresql://postgres:postgres@127.0.0.1:5432/whatsub_progressive_test'
npm test -- tests/mobile-analysis-postgres.integration.test.ts
```

Expected: PASS for create/finalize/delete transaction behavior on real PostgreSQL, not only pg-mem. The guarded test rejects non-loopback hosts and database names outside the test-name pattern.

- [ ] **Step 3: Run complete iOS CI-equivalent verification**

```bash
xcodegen generate
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
```

Expected: build and tests exit 0.

- [ ] **Step 4: Verify old-client compatibility manually against a local backend**

Submit a job using the existing create payload, confirm the response remains the same shape except `resultEntryId` is now non-null, confirm `/api/library/list` immediately contains one English-only card, complete the worker, and confirm the same ID becomes bilingual without duplication.

- [ ] **Step 5: Verify failure and deletion manually**

Cancel one running job and confirm its English card opens. Resume it and confirm completed batches remain. Delete a second active card and confirm the job cannot resume and no worker turn recreates the card.

- [ ] **Step 6: Commit verification-only adjustments**

```bash
git add tests/mobile-analysis-postgres.integration.test.ts
git commit -m "test: verify progressive mobile analysis rollout"
```

- [ ] **Step 7: Deploy in compatibility order**

Deploy the backend first with workers at existing concurrency. Confirm health/readiness and one test account's provisional-create/incremental/finalize flow. Then push the iOS branch and run CI/TestFlight only when explicitly requested; backend deployment does not authorize an iOS release by itself.
