# Managed Mobile Background Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move managed-AI YouTube import orchestration into a bounded, persistent backend queue while keeping BYOK on-device with durable batch resume.

**Architecture:** iOS still obtains YouTube metadata and captions. Managed mode submits one idempotent job and can leave the foreground; two fair backend workers process one 50-cue batch at a time through a four-slot priority DeepSeek gateway, persist every result, assemble a caption-only Library entry, and notify iOS. BYOK retains the current direct-provider pipeline but checkpoints each completed batch locally.

**Tech Stack:** Swift 5.10/SwiftUI/iOS 16+, Hono/TypeScript/Node 22, PostgreSQL, Vitest/pg-mem, XCTest, DeepSeek OpenAI-compatible SSE, existing ActivityKit/APNs infrastructure.

## Global Constraints

- Free + managed AI: backend job, maximum 1,200 seconds per video, 200K lifetime tokens.
- Pro + managed AI: backend job, no product duration limit, 5M tokens per month.
- BYOK: iOS pipeline, no product duration limit, key never leaves Keychain, pauses in background and resumes from a durable checkpoint.
- Background workers default to 2; all DeepSeek outbound connections default to 4; background connections default to 2.
- At most one in-flight batch per account, three unfinished jobs per account, and 100 unfinished jobs globally.
- One worker processes one 50-cue batch and yields; no worker owns a whole video continuously.
- No PostgreSQL connection may remain checked out while awaiting DeepSeek.
- Caption-only analysis is independent of existing desktop/OSS duration and size limits.
- No new third-party Swift dependency.
- Every production behavior is introduced test-first and committed independently.

## File Structure

### `whatsub-license`

- Create `src/lib/mobileAnalysis.ts`: job/batch types, cue validation, batching, status/error constants.
- Create `src/lib/prioritySemaphore.ts`: global priority-aware outbound connection limiter.
- Create `src/lib/deepseekGateway.ts`: single sanitized DeepSeek request/open-stream implementation shared by relay and worker.
- Create `src/lib/mobileAnalysisPrompts.ts`: server copy of the current iOS analysis and summary prompts.
- Create `src/lib/mobileAnalysisParser.ts`: SSE delta/usage and JSONL cue/summary parsing.
- Create `src/lib/mobileAnalysisWorker.ts`: one-batch leasing loop, quota checks, retries, final assembly, cancellation.
- Create `src/routes/mobileAnalysis.ts`: authenticated create/list/get/cancel/resume endpoints.
- Modify `schema.sql`: add `mobile_analysis_jobs` and `mobile_analysis_batches`.
- Modify `src/lib/types.ts`: persisted and API mobile-analysis types.
- Modify `src/lib/db.ts`: short-transaction queue persistence methods.
- Modify `src/routes/llm.ts`: use the shared gateway/semaphore without changing its wire contract.
- Modify `src/routes/library.ts`: apply duration cap only when `videoKey` is present.
- Modify `src/index.ts`: route mounting, worker lifecycle, safe environment defaults.
- Modify `src/lib/cleanup.ts`: prune terminal job/batch payloads after retention.
- Create focused tests under `tests/mobile-analysis-*.test.ts` and update `tests/library-routes.test.ts`, `tests/llm-routes.test.ts`, and `tests/schema.test.ts`.

### `whatsub-mobile`

- Create `whatsub-mobile/Import/ManagedAnalysisModels.swift`: job request/response/status DTOs and typed errors.
- Create `whatsub-mobile/Import/ManagedAnalysisClient.swift`: protocol plus production `WhatsubAPI` adapter.
- Create `whatsub-mobile/Import/AnalysisCheckpointStore.swift`: atomic BYOK batch persistence.
- Modify `whatsub-mobile/Import/YouTubeCaptionExtractor.swift`: return captions plus duration.
- Modify `whatsub-mobile/Import/CaptionCache.swift`: cache duration backward-compatibly.
- Modify `whatsub-mobile/LLM/AnalysisEngine.swift`: resumable batch API and checkpoint callbacks.
- Modify `whatsub-mobile/Import/ImportViewModel.swift`: managed-job/BYOK branching and typed states.
- Modify `whatsub-mobile/Import/ImportView.swift`: durable managed progress, correct duration/quota actions, BYOK foreground copy.
- Modify `whatsub-mobile/Me/ImportQueueView.swift`: show mobile-analysis jobs alongside desktop imports.
- Modify `whatsub-mobile/Networking/Endpoints.swift`, `DTOs.swift`, and `WhatsubAPI.swift`: endpoint wiring.
- Modify `whatsub-mobile/Shared/ImportActivityAttributes.swift` and widget views: carry an optional completed Library entry ID.
- Modify `whatsub-mobile/App/AppState.swift`, `WhatsubMobileApp.swift`, and `Library/LibraryView.swift`: deep-link into the completed entry.
- Modify `whatsub-mobile/App/LiveActivityCoordinator.swift`: reuse the aggregate import activity for managed jobs.
- Add XCTest files for extraction metadata, duration policy, managed flow, checkpointing, and job status decoding.

---

### Task 1: Persist Mobile Analysis Jobs and Batches

**Files:**
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/schema.sql`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/types.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/db.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/mobileAnalysis.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/mobile-analysis-db.test.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/schema.test.ts`

**Interfaces:**
- Produces `MobileAnalysisTier = 'free' | 'pro'`.
- Produces `MobileAnalysisJobStatus = 'queued' | 'running' | 'paused_quota' | 'completed' | 'failed' | 'cancelled'`.
- Produces `Database.createMobileAnalysisJob`, `getMobileAnalysisJob`, `listMobileAnalysisJobs`, `cancelMobileAnalysisJob`, `claimMobileAnalysisBatch`, `completeMobileAnalysisBatch`, `releaseMobileAnalysisLease`, `pauseMobileAnalysisForQuota`, and `completeMobileAnalysisJob`.
- `claimMobileAnalysisBatch(workerId, now, leaseMs)` returns one `MobileAnalysisClaim` containing only the next unfinished 50-cue slice.

- [ ] **Step 1: Write failing schema and DB tests**

```ts
it('creates one idempotent job and immutable successful batches', async () => {
  const first = await db.createMobileAnalysisJob(jobInput({ idempotencyKey: 'device:video:captions-v1' }));
  const second = await db.createMobileAnalysisJob(jobInput({ idempotencyKey: 'device:video:captions-v1' }));
  expect(first.id).toBe(second.id);

  const claim = await db.claimMobileAnalysisBatch('worker-a', 1_000, 300_000);
  expect(claim?.batchIndex).toBe(0);
  await db.completeMobileAnalysisBatch(claim!, [{ index: 0, text: 'Hello' }], 100, 200, 2_000);
  await expect(db.completeMobileAnalysisBatch(claim!, [], 0, 0, 3_000))
    .resolves.toBe('already_completed');
});

it('expires a lease and reclaims only the unfinished batch', async () => {
  await db.createMobileAnalysisJob(jobInput());
  const stale = await db.claimMobileAnalysisBatch('dead-worker', 1_000, 100);
  expect(await db.claimMobileAnalysisBatch('early-worker', 1_050, 100)).toBeNull();
  const reclaimed = await db.claimMobileAnalysisBatch('new-worker', 1_101, 100);
  expect(reclaimed?.batchIndex).toBe(stale?.batchIndex);
});
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
pnpm test -- tests/mobile-analysis-db.test.ts tests/schema.test.ts
```

Expected: FAIL because the tables, types, and Database methods do not exist.

- [ ] **Step 3: Add the two tables and indexes**

```sql
CREATE TABLE IF NOT EXISTS mobile_analysis_jobs (
  id UUID PRIMARY KEY,
  owner_email TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  youtube_id TEXT NOT NULL,
  source_url TEXT NOT NULL,
  title TEXT NOT NULL,
  duration_sec INTEGER,
  cues_json JSONB NOT NULL,
  transcript_srt TEXT NOT NULL,
  thumb_data TEXT,
  tier TEXT NOT NULL CHECK (tier IN ('free','pro')),
  status TEXT NOT NULL CHECK (status IN ('queued','running','paused_quota','completed','failed','cancelled')),
  total_batches INTEGER NOT NULL,
  completed_batches INTEGER NOT NULL DEFAULT 0,
  last_served_at BIGINT NOT NULL DEFAULT 0,
  lease_owner TEXT,
  lease_expires_at BIGINT,
  next_run_at BIGINT NOT NULL,
  cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
  tokens_in BIGINT NOT NULL DEFAULT 0,
  tokens_out BIGINT NOT NULL DEFAULT 0,
  result_entry_id TEXT,
  error_code TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  UNIQUE (owner_email, idempotency_key)
);

CREATE TABLE IF NOT EXISTS mobile_analysis_batches (
  job_id UUID NOT NULL REFERENCES mobile_analysis_jobs(id) ON DELETE CASCADE,
  batch_index INTEGER NOT NULL,
  phase TEXT NOT NULL CHECK (phase IN ('cues','summary')),
  cue_start INTEGER NOT NULL,
  cue_end INTEGER NOT NULL,
  result_json JSONB,
  tokens_in BIGINT NOT NULL DEFAULT 0,
  tokens_out BIGINT NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0,
  completed_at BIGINT,
  PRIMARY KEY (job_id, batch_index)
);

CREATE INDEX IF NOT EXISTS mobile_analysis_sched_idx
  ON mobile_analysis_jobs(status, next_run_at, updated_at);
CREATE INDEX IF NOT EXISTS mobile_analysis_owner_idx
  ON mobile_analysis_jobs(owner_email, created_at DESC);
```

`total_batches` and `completed_batches` count cue batches only. Create one
additional `phase='summary'` row at `batch_index=total_batches`; its persisted
`result_json` makes finalization restart-safe and prevents a successful summary
from being requested again after a later crash.

- [ ] **Step 4: Implement short-transaction DB methods**

Use `pool.connect()` only around `BEGIN`/`COMMIT` claim and completion blocks.
The claim query must use `FOR UPDATE SKIP LOCKED`, reject jobs whose owner has
another unexpired lease, select by `next_run_at` then `last_served_at`, increment
only the selected phase attempt, and commit before returning cues. Persist
`last_served_at` after each settled phase so a long job rotates behind other
eligible accounts.

```ts
export interface MobileAnalysisClaim {
  jobId: string;
  ownerEmail: string;
  tier: MobileAnalysisTier;
  batchIndex: number;
  cues: MobileAnalysisCue[];
  leaseOwner: string;
  leaseExpiresAt: number;
  phase: 'cues' | 'summary';
}
```

- [ ] **Step 5: Run focused tests and full backend typecheck**

```powershell
pnpm test -- tests/mobile-analysis-db.test.ts tests/schema.test.ts
pnpm typecheck
```

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add schema.sql src/lib/types.ts src/lib/db.ts src/lib/mobileAnalysis.ts tests/mobile-analysis-db.test.ts tests/schema.test.ts
git commit -m "feat: persist mobile analysis jobs"
```

### Task 2: Add a Priority-Bounded DeepSeek Gateway

**Files:**
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/prioritySemaphore.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/deepseekGateway.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/priority-semaphore.test.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/deepseek-gateway.test.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/routes/llm.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/llm-routes.test.ts`

**Interfaces:**
- Produces `PrioritySemaphore.acquire('interactive' | 'background', signal?)` returning an idempotent release closure.
- Produces `DeepseekGateway.openStream(request, priority, signal)` returning the upstream `Response` while holding one permit until its body finishes or aborts.
- Global limit defaults to 4; background-held permits default to 2; queued interactive requests are selected before background requests.

- [ ] **Step 1: Write failing limiter tests**

```ts
it('never exceeds four total or two background permits', async () => {
  const sem = new PrioritySemaphore({ total: 4, background: 2 });
  const bg1 = await sem.acquire('background');
  const bg2 = await sem.acquire('background');
  let thirdBackgroundEntered = false;
  const bg3 = sem.acquire('background').then((release) => {
    thirdBackgroundEntered = true;
    return release;
  });
  await Promise.resolve();
  expect(thirdBackgroundEntered).toBe(false);
  bg1();
  (await bg3)();
  bg2();
});

it('serves an interactive waiter before an older background waiter', async () => {
  const sem = new PrioritySemaphore({ total: 1, background: 1 });
  const release = await sem.acquire('background');
  const order: string[] = [];
  const oldBackground = sem.acquire('background').then((r) => { order.push('background'); r(); });
  const interactive = sem.acquire('interactive').then((r) => { order.push('interactive'); r(); });
  release();
  await Promise.all([oldBackground, interactive]);
  expect(order).toEqual(['interactive', 'background']);
});
```

- [ ] **Step 2: Verify RED**

```powershell
pnpm test -- tests/priority-semaphore.test.ts tests/deepseek-gateway.test.ts
```

- [ ] **Step 3: Implement the semaphore and gateway**

The gateway, not callers, forces the configured model, `stream: true`,
`include_usage`, output cap, DeepSeek thinking disabled, API key, and timeout.
Release the permit from a wrapped stream `finally` path and from every early
error/abort path.

```ts
export interface DeepseekRequest {
  messages: Array<{ role: string; content: string }>;
  maxTokens?: number;
  temperature?: number;
  tools?: unknown[];
  toolChoice?: unknown;
}
```

- [ ] **Step 4: Refactor `/api/llm/v1/chat/completions` to use the gateway**

Keep authorization, rate limits, quota responses, SSE bytes, tool forwarding,
and usage accounting byte-for-byte compatible. Mark this route as
`interactive`; worker calls added later use `background`.

- [ ] **Step 5: Verify focused and regression tests**

```powershell
pnpm test -- tests/priority-semaphore.test.ts tests/deepseek-gateway.test.ts tests/llm-routes.test.ts
pnpm typecheck
```

- [ ] **Step 6: Commit**

```powershell
git add src/lib/prioritySemaphore.ts src/lib/deepseekGateway.ts src/routes/llm.ts tests/priority-semaphore.test.ts tests/deepseek-gateway.test.ts tests/llm-routes.test.ts
git commit -m "refactor: bound managed llm connections"
```

### Task 3: Port Analysis Prompts and Deterministic SSE Parsing

**Files:**
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/mobileAnalysisPrompts.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/mobileAnalysisParser.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/mobile-analysis-parser.test.ts`
- Read as reference: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile/whatsub-mobile/LLM/AnalysisPrompts.swift`
- Read as reference: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile/whatsub-mobile/LLM/JsonLineParser.swift`

**Interfaces:**
- Produces `buildCueMessages(cues)` and `buildSummaryMessages(subtitles)` matching current iOS semantics.
- Produces `consumeAnalysisSse(response)` returning `{ text, usage }` and `parseCueJsonLines(text)` returning validated cue results.
- Accepts `delta.content` first and `delta.reasoning_content` only when content is empty.

- [ ] **Step 1: Write failing fixtures for fragmented SSE and JSONL**

```ts
it('joins fragmented content and captures the terminal usage frame', async () => {
  const response = sseResponse([
    `data: {"choices":[{"delta":{"content":"{\\\"index\\\":0,"}}]}\n\n`,
    `data: {"choices":[{"delta":{"content":"\\\"text\\\":\\\"Hi\\\"}\\n"}}]}\n\n`,
    `data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":7}}\n\n`,
    `data: [DONE]\n\n`,
  ]);
  const result = await consumeAnalysisSse(response);
  expect(result.usage).toEqual({ tokensIn: 12, tokensOut: 7 });
  expect(parseCueJsonLines(result.text)).toHaveLength(1);
});
```

- [ ] **Step 2: Verify RED**

```powershell
pnpm test -- tests/mobile-analysis-parser.test.ts
```

- [ ] **Step 3: Port exact prompts and implement bounded parsing**

Reject output cues whose index/time/endTime cannot map back to the submitted
batch. Never evaluate model output as code. Limit buffered SSE text and JSONL
line length using the configured per-request output ceiling.

- [ ] **Step 4: Verify tests and commit**

```powershell
pnpm test -- tests/mobile-analysis-parser.test.ts
git add src/lib/mobileAnalysisPrompts.ts src/lib/mobileAnalysisParser.ts tests/mobile-analysis-parser.test.ts
git commit -m "feat: parse server-side mobile analysis"
```

### Task 4: Expose Authenticated Job APIs and Duration Policy

**Files:**
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/routes/mobileAnalysis.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/mobile-analysis-routes.test.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/index.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/routes/library.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/library-routes.test.ts`

**Interfaces:**
- Mounts `mobileAnalysisRoute(db)` at `/api/library/mobile-analysis`.
- `POST /jobs` accepts `{ idempotencyKey, youtubeId, sourceUrl, title, durationSec, cues, transcriptSrt, thumbData? }`.
- `GET /jobs`, `GET /jobs/:id`, `POST /jobs/:id/cancel`, and `POST /jobs/:id/resume` are owner-scoped.
- Create returns `202` and a `MobileAnalysisJobView`; duplicate idempotency returns the same job.
- `MobileAnalysisJobView` exposes `completedCues`, `totalCues`, `tokensIn`, `tokensOut`, sanitized `errorCode`, and optional `resultEntryId`; it never returns raw cues, SRT, batch JSON, owner email, or thumbnail bytes.

- [ ] **Step 1: Write failing route tests for the full policy matrix**

```ts
it.each([
  { pro: false, duration: 1200, expected: 202 },
  { pro: false, duration: 1201, expected: 413 },
  { pro: true, duration: 24 * 3600, expected: 202 },
])('applies managed duration policy %#', async ({ pro, duration, expected }) => {
  const token = await sessionFor(pro);
  const res = await createJob(token, validBody({ durationSec: duration }));
  expect(res.status).toBe(expected);
});

it('does not expose another account job', async () => {
  const ownerJob = await createJob(await sessionForEmail('a@x.com'), validBody());
  const id = (await ownerJob.json()).jobId;
  expect((await getJob(await sessionForEmail('b@x.com'), id)).status).toBe(404);
});
```

Also add a regression proving `/library/sync` permits a caption-only entry over
1,200 seconds when `videoKey` is absent, while the same duration with a
`videoKey` still returns `video_too_long`.

- [ ] **Step 2: Verify RED**

```powershell
pnpm test -- tests/mobile-analysis-routes.test.ts tests/library-routes.test.ts
```

- [ ] **Step 3: Implement validation and queue caps**

Validate body bytes before JSON expansion, maximum cue count, per-cue text and
timestamp bounds, source identity, strictly positive known duration for managed
jobs, three unfinished jobs per owner, and 100 globally. Return typed errors:
`video_too_long`, `duration_unknown`, `queue_limit`, `server_busy`,
`free_used_up`, and `quota_exceeded`.

Use explicit technical ceilings: 16 MiB request body, 12,000 cues, 4 KiB UTF-8
text per cue, 6 MiB SRT, 300-character title, 1 MiB thumbnail, finite
non-negative timestamps, and an 11-character YouTube ID that matches the source
URL. These are abuse guards, not duration limits. The request does not accept a
system prompt, model name, provider URL, or arbitrary model parameters. Return
`queue_limit` for the per-owner cap and retryable `server_busy` for the global
cap. Determine and persist the `free`/`pro` tier once at creation; a job accepted
as Pro remains Pro if the subscription later expires.

- [ ] **Step 4: Mount the route and narrow `/library/sync` media fencing**

Change the existing duration condition to:

```ts
if (videoKey && durationSec !== undefined && durationSec > limits.maxVideoSeconds) {
  // existing cleanup + video_too_long response
}
```

Do not change `/upload-url` or replacement completion; those always concern OSS
media and keep their existing limits.

- [ ] **Step 5: Verify and commit**

```powershell
pnpm test -- tests/mobile-analysis-routes.test.ts tests/library-routes.test.ts
pnpm typecheck
git add src/routes/mobileAnalysis.ts src/index.ts src/routes/library.ts tests/mobile-analysis-routes.test.ts tests/library-routes.test.ts
git commit -m "feat: add managed mobile analysis api"
```

### Task 5: Process One Fair, Resumable Batch

**Files:**
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/mobileAnalysisWorker.ts`
- Create: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/mobile-analysis-worker.test.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/db.ts`

**Interfaces:**
- Produces `MobileAnalysisWorker.runOne(workerId, now): Promise<'worked' | 'idle'>`.
- Consumes `DeepseekGateway`, Database claims, prompt/parser functions, and `LlmRelayConfig`.
- A worker call handles exactly one cue batch or one final-summary phase.

- [ ] **Step 1: Write failing worker tests**

Cover successful batch persistence, two concurrent workers taking different
owners, one owner never receiving two simultaneous claims, cancellation after
an in-flight batch, timeout retry count, circuit-breaker delay, free lifetime
quota pause, Pro monthly quota pause, accepted-Pro continuation after expiry,
summary-result persistence, lease recovery, and a pool spy proving every DB
client is released before the fake gateway promise is allowed to resolve.

```ts
it('yields after one batch so another owner is served', async () => {
  await seedJob('a@x.com', 3);
  await seedJob('b@x.com', 1);
  await worker.runOne('w1', 1_000);
  await worker.runOne('w1', 1_001);
  expect(gateway.ownerOrder).toEqual(['a@x.com', 'b@x.com']);
});

it('pauses instead of opening DeepSeek when quota is exhausted', async () => {
  await seedFreeUsage('free@x.com', 200_000);
  const job = await seedJob('free@x.com', 1, 'free');
  await worker.runOne('w1', 1_000);
  expect(gateway.calls).toHaveLength(0);
  expect((await db.getMobileAnalysisJob(job, 'free@x.com'))?.status).toBe('paused_quota');
});
```

- [ ] **Step 2: Verify RED**

```powershell
pnpm test -- tests/mobile-analysis-worker.test.ts
```

- [ ] **Step 3: Implement one-batch execution**

Use an `AbortController` with 300 seconds. Acquire a background gateway permit
only after quota and cancellation checks. Persist actual usage from the SSE
terminal frame. Retry retryable upstream failures at `1s + jitter`, then
`4s + jitter`; mark a deterministic model-output failure as `failed` without an
infinite retry.

The successful completion transaction conditionally fills the unfinished batch
row, increments job totals, and records those tokens in the existing
`llm_usage` ledger exactly once. Free checks sum every period for that email;
Pro checks the current UTC month. A stale worker response that loses the
conditional update records neither job totals nor ledger usage a second time.
Five consecutive retryable upstream failures open a process-wide 30-second
circuit; one successful response closes it.

After every cue row is complete, claim the dedicated summary row as one normal
fair-scheduling turn. Build its prompt from ordered cue results with a hard
120,000-character deterministic budget: preserve the first and last sections
and uniformly sample the middle when necessary. Persist the parsed key phrases
and usage into that row before releasing the lease. A later worker finding the
summary row complete proceeds to finalization without opening DeepSeek again.

- [ ] **Step 4: Verify concurrency and worker tests**

```powershell
pnpm test -- tests/mobile-analysis-worker.test.ts tests/priority-semaphore.test.ts
pnpm typecheck
```

- [ ] **Step 5: Commit**

```powershell
git add src/lib/mobileAnalysisWorker.ts src/lib/db.ts tests/mobile-analysis-worker.test.ts
git commit -m "feat: process bounded mobile analysis batches"
```

### Task 6: Assemble Library Results and Publish Progress

**Files:**
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/mobileAnalysisWorker.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/db.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/apnsPush.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/mobile-analysis-worker.test.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/apns-push.test.ts`

**Interfaces:**
- Final phase reads completed cue batches and the already-persisted summary row, calls `upsertLibraryEntry` with no `videoKey`, and transactionally stores `resultEntryId` plus `completed`.
- `Database.getWorkAggregateForEmail` combines desktop import-queue and mobile-analysis counts without transcript contents.
- Progress publisher reuses the existing Live Activity token registry and sends optional `recentEntryId` when a mobile job completes.

- [ ] **Step 1: Write failing finalization tests**

```ts
it('assembles ordered batches once and completes a caption-only Library entry', async () => {
  const job = await seedCompletedBatchesOutOfOrder();
  await worker.runOne('w1', 5_000);
  const entry = await db.getLibraryEntry(job, ownerEmail);
  expect(entry?.durationSec).toBe(3_601);
  expect(entry?.videoKey).toBeNull();
  expect(entry?.analysisJson.subtitles.map((c: { index: number }) => c.index))
    .toEqual([0, 1, 2]);
  expect((await db.getMobileAnalysisJob(job, ownerEmail))?.status).toBe('completed');
});
```

Add APNs regressions proving the aggregate counts both desktop queue work and
managed jobs, emits `recentEntryId` only for a completed mobile job, and never
places source URL, caption text, email, or bearer tokens in the payload.

- [ ] **Step 2: Verify RED**

```powershell
pnpm test -- tests/mobile-analysis-worker.test.ts tests/apns-push.test.ts
```

- [ ] **Step 3: Implement finalization and notification**

Use the job UUID as the deterministic Library entry ID so retrying finalization
cannot create duplicates. Finalization is not eligible until the summary row is
terminal. If Library upsert succeeds but notification fails, keep the job
completed and retry notification best-effort; never rerun AI. Existing desktop
queue push tests must remain unchanged except for the new optional field.

- [ ] **Step 4: Verify and commit**

```powershell
pnpm test -- tests/mobile-analysis-worker.test.ts tests/apns-push.test.ts
git add src/lib/mobileAnalysisWorker.ts src/lib/db.ts src/lib/apnsPush.ts tests/mobile-analysis-worker.test.ts tests/apns-push.test.ts
git commit -m "feat: finalize background analysis into library"
```

### Task 7: Wire Safe Worker Lifecycle, Cleanup, and Metrics

**Files:**
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/index.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/cleanup.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/src/lib/db.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/cleanup.test.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/tests/auth-routes.test.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/README.md`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/CLAUDE.md` if present and tracked.

**Interfaces:**
- Environment: `MOBILE_ANALYSIS_ENABLED=false`, `MOBILE_ANALYSIS_WORKERS=2`, `LLM_GLOBAL_CONNECTIONS=4`, `LLM_BACKGROUND_CONNECTIONS=2`, `MOBILE_ANALYSIS_QUEUE_MAX=100`, `MOBILE_ANALYSIS_OWNER_MAX=3`.
- Missing or malformed values use safe defaults or disable workers; zero never means unlimited.

- [ ] **Step 1: Write failing config and cleanup tests**

Assert bounded default parsing, rejection of negative/unreasonably high values,
terminal payload pruning after 30 days, preservation of queued/running jobs,
and `deleteUserAccount` deleting owned jobs (batch rows then disappear through
their `ON DELETE CASCADE`).

- [ ] **Step 2: Verify RED**

```powershell
pnpm test -- tests/cleanup.test.ts tests/mobile-analysis-worker.test.ts
```

- [ ] **Step 3: Start and stop workers safely**

Start workers only in the CLI entrypoint after DB construction. Keep
`buildApp()` pure for tests. On `SIGTERM`/`SIGINT`, stop claiming, abort idle
waits, allow active batch persistence for a bounded grace period, then close the
pool. Log only counts, durations, worker IDs, job IDs, and hashed owner IDs.
Extend the existing explicit `Database.deleteUserAccount` deletion sequence with
`DELETE FROM mobile_analysis_jobs WHERE owner_email = $1`; do not rely on a
foreign key to an account table because this backend's account data is spread
across email-keyed tables.

- [ ] **Step 4: Verify backend suite and commit**

```powershell
pnpm typecheck
pnpm build
pnpm test
git add src/index.ts src/lib/cleanup.ts src/lib/db.ts tests/cleanup.test.ts tests/auth-routes.test.ts README.md
# Add CLAUDE.md only if it exists, is tracked, and was updated.
git commit -m "feat: operate mobile analysis workers safely"
```

### Task 8: Return YouTube Captions with Duration

**Files:**
- Modify: `whatsub-mobile/Import/YouTubeCaptionExtractor.swift`
- Modify: `whatsub-mobile/Import/CaptionCache.swift`
- Modify: `whatsub-mobileTests/YouTubeCaptionExtractorTests.swift`
- Modify: `whatsub-mobileTests/CaptionCacheTests.swift`

**Interfaces:**
- Produces `CaptionExtractionResult { let cues: [Cue]; let durationSec: Int? }`.
- `YouTubeCaptionExtractor.extract(...) async throws -> CaptionExtractionResult`.
- Cache entries persist duration; old cue-only cache files decode with `durationSec == nil` and force one metadata refresh before managed submission.

- [ ] **Step 1: Write failing duration and cache compatibility tests**

```swift
func testExtractReturnsInnertubeDuration() async throws {
    let playerJSON = """
    {"playabilityStatus":{"status":"OK"},
     "videoDetails":{"lengthSeconds":"1201"},
     "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
       {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
     ]}}}
    """.data(using: .utf8)!
    let result = try await YouTubeCaptionExtractor.extract(
        videoId: "abcdefghijk", cache: cache, fetcher: fixture(playerJSON)
    )
    XCTAssertEqual(result.durationSec, 1201)
    XCTAssertEqual(result.cues.count, 2)
}
```

- [ ] **Step 2: Verify RED on macOS CI-equivalent command**

```bash
xcodegen generate
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  test -only-testing:whatsub-mobileTests/YouTubeCaptionExtractorTests \
       -only-testing:whatsub-mobileTests/CaptionCacheTests
```

- [ ] **Step 3: Implement structured extraction and cache migration**

Parse `lengthSeconds` as a positive, finite `Int`. Do not infer duration from
the final cue for managed policy. Preserve current caption-language and error
handling.

- [ ] **Step 4: Verify and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  test -only-testing:whatsub-mobileTests/YouTubeCaptionExtractorTests \
       -only-testing:whatsub-mobileTests/CaptionCacheTests
git add whatsub-mobile/Import/YouTubeCaptionExtractor.swift whatsub-mobile/Import/CaptionCache.swift whatsub-mobileTests/YouTubeCaptionExtractorTests.swift whatsub-mobileTests/CaptionCacheTests.swift
git commit -m "feat: retain youtube video duration"
```

### Task 9: Add Managed Analysis Networking and Typed Policy

**Files:**
- Create: `whatsub-mobile/Import/ManagedAnalysisModels.swift`
- Create: `whatsub-mobile/Import/ManagedAnalysisClient.swift`
- Modify: `whatsub-mobile/Networking/Endpoints.swift`
- Modify: `whatsub-mobile/Networking/DTOs.swift`
- Modify: `whatsub-mobile/Networking/WhatsubAPI.swift`
- Create: `whatsub-mobileTests/ManagedAnalysisClientTests.swift`

**Interfaces:**
- Produces `ManagedAnalysisClientProtocol.createJob`, `job`, `jobs`, `cancel`, and `resume`.
- Produces `ManagedAnalysisJob` with typed `Status` and `tier`.
- Maps `video_too_long`, `duration_unknown`, `free_used_up`, `quota_exceeded`, `server_busy`, and `upstream_unavailable` without flattening them into a string.

- [ ] **Step 1: Write failing request/response tests**

```swift
func testCreateUsesStableIdempotencyAndDecodes202() async throws {
    let client = fixtureClient(status: 202, json: jobJSON(status: "queued"))
    let job = try await client.createJob(request, token: "session")
    XCTAssertEqual(job.status, .queued)
    XCTAssertEqual(recordedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer session")
    XCTAssertEqual(decodedBody.idempotencyKey, request.idempotencyKey)
}
```

- [ ] **Step 2: Verify RED, implement minimal client, then verify GREEN**

Run the focused XCTest command from Task 8 with
`-only-testing:whatsub-mobileTests/ManagedAnalysisClientTests`.

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Import/ManagedAnalysisModels.swift whatsub-mobile/Import/ManagedAnalysisClient.swift whatsub-mobile/Networking/Endpoints.swift whatsub-mobile/Networking/DTOs.swift whatsub-mobile/Networking/WhatsubAPI.swift whatsub-mobileTests/ManagedAnalysisClientTests.swift
git commit -m "feat: add managed analysis job client"
```

### Task 10: Branch Import Flow by Managed AI vs BYOK

**Files:**
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Modify: `whatsub-mobile/Import/ImportView.swift`
- Create: `whatsub-mobileTests/ImportManagedAnalysisTests.swift`

**Interfaces:**
- `ImportViewModel` receives `ManagedAnalysisClientProtocol` plus an entitlement refresher that can distinguish fresh server state from cached/unknown state.
- Managed mode submits after extraction and enters `.managedJob(ManagedAnalysisJob)`.
- BYOK mode enters the local `AnalysisEngine` path.
- A fresh server result of free blocks `durationSec > 1200` on-device; stale or unavailable entitlement state submits the bounded metadata job and lets the backend decide, so a real Pro user is never blocked by stale local state.
- Backend response remains authoritative in every case.

- [ ] **Step 1: Write failing flow tests**

```swift
func testFreeManagedOverTwentyMinutesStopsBeforeJobCreation() async {
    let vm = makeVM(managed: true, entitlement: .freshFree, extractionDuration: 1201)
    await vm.run(urlOrId: youtubeURL, token: "t")
    XCTAssertEqual(client.createCalls, 0)
    XCTAssertEqual(vm.state, .managedPolicy(.videoTooLong(duration: 1201, limit: 1200)))
}

func testUnknownEntitlementLetsBackendCorrectStaleFreeState() async {
    let vm = makeVM(managed: true, entitlement: .unknown, extractionDuration: 1201)
    await vm.run(urlOrId: youtubeURL, token: "t")
    XCTAssertEqual(client.createCalls, 1)
}

func testManagedSubmissionDoesNotRunLocalAnalysisEngine() async {
    let vm = makeVM(managed: true, pro: true, extractionDuration: 86_400)
    await vm.run(urlOrId: youtubeURL, token: "t")
    XCTAssertEqual(client.createCalls, 1)
    XCTAssertEqual(localAnalyzer.calls, 0)
}
```

- [ ] **Step 2: Verify RED**

Run `ImportManagedAnalysisTests` in the simulator.

- [ ] **Step 3: Implement typed states and UI**

Managed success says the user may close whatSub. A free long-video screen offers
subscription and switching to BYOK. Quota screens do not show VPN help or
“重试 AI 解析”. BYOK explicitly says switching apps pauses and resumes.
Once `POST /jobs` returns, dismissing the import sheet cancels only local
polling, never the server job; a separate explicit “取消后台解析” action calls
the cancel endpoint. The sheet may become dismissible in durable managed-job
states while retaining the current cancellation behavior during extraction and
BYOK execution. Sync real `durationSec` for every completed BYOK result when it
is known.

- [ ] **Step 4: Verify and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  test -only-testing:whatsub-mobileTests/ImportManagedAnalysisTests
git add whatsub-mobile/Import/ImportViewModel.swift whatsub-mobile/Import/ImportView.swift whatsub-mobileTests/ImportManagedAnalysisTests.swift
git commit -m "feat: submit managed imports as background jobs"
```

### Task 11: Make BYOK Analysis Durable and Resumable

**Files:**
- Create: `whatsub-mobile/Import/AnalysisCheckpointStore.swift`
- Modify: `whatsub-mobile/LLM/AnalysisEngine.swift`
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Modify: `whatsub-mobile/Import/ImportView.swift`
- Create: `whatsub-mobileTests/AnalysisCheckpointStoreTests.swift`
- Modify: `whatsub-mobileTests/AnalysisEngineTests.swift`

**Interfaces:**
- Produces `AnalysisCheckpoint` keyed by SHA-256 of source ID plus normalized cues, containing completed cue batches and an optional completed summary.
- `AnalysisEngine.analyze(cues, completedBatches:completedSummary:onBatchCompleted:onSummaryCompleted:onProgress:)` skips completed work and reports each newly completed result before opening the next request.
- Store uses atomic file replacement and `FileProtectionType.completeUntilFirstUserAuthentication`.

- [ ] **Step 1: Write failing checkpoint and resume tests**

```swift
func testResumeSkipsCompletedBatches() async throws {
    let checkpoint = AnalysisCheckpoint(completed: [0: firstBatchResult])
    let result = try await engine.analyze(
        cues,
        completedBatches: checkpoint.completed,
        completedSummary: checkpoint.summary,
        onBatchCompleted: { _, _ in },
        onSummaryCompleted: { _ in },
        onProgress: { _, _ in }
    )
    XCTAssertEqual(client.requestedBatchIndices, [1, 2])
    XCTAssertEqual(result.subtitles.count, cues.count)
}
```

- [ ] **Step 2: Verify RED, implement atomic persistence, verify GREEN**

Run `AnalysisCheckpointStoreTests` and `AnalysisEngineTests` on the simulator.

- [ ] **Step 3: Add lifecycle behavior**

Store checkpoints under Application Support. `ImportView` observes
`scenePhase`: on background, it sets a flag that prevents opening the next BYOK
batch but does not cancel the current request manually; on foreground, it calls
the same serialized resume entry point. A process relaunch discovers the
checkpoint after the user reopens the same source. Reject a partial or
index-mismatched batch instead of checkpointing it. Delete checkpoints after
completed sync or explicit cancellation; prune abandoned entries after seven
days.

- [ ] **Step 4: Verify and commit**

```bash
git add whatsub-mobile/Import/AnalysisCheckpointStore.swift whatsub-mobile/LLM/AnalysisEngine.swift whatsub-mobile/Import/ImportViewModel.swift whatsub-mobile/Import/ImportView.swift whatsub-mobileTests/AnalysisCheckpointStoreTests.swift whatsub-mobileTests/AnalysisEngineTests.swift
git commit -m "feat: resume byok analysis by batch"
```

### Task 12: Surface Durable Jobs and Live Activity Completion

**Files:**
- Modify: `whatsub-mobile/Me/ImportQueueView.swift`
- Modify: `whatsub-mobile/Shared/ImportActivityAttributes.swift`
- Modify: `whatsub-widget/ImportActivityWidget.swift`
- Modify: `whatsub-widget/LockScreenCard.swift`
- Modify: `whatsub-mobile/App/LiveActivityCoordinator.swift`
- Modify: `whatsub-mobile/App/WhatsubMobileApp.swift`
- Modify: `whatsub-mobile/App/AppState.swift`
- Modify: `whatsub-mobile/Library/LibraryView.swift`
- Create: `whatsub-mobileTests/ManagedAnalysisPresentationTests.swift`

**Interfaces:**
- Import Queue displays a “手机后台解析” section sourced from `GET /jobs`.
- Foreground refresh and visible-view polling update exact progress; no background polling loop.
- Managed submission seeds the existing aggregate `ImportActivityAttributes` activity with one in-progress item.
- `ImportActivityAttributes.ContentState` gains optional `recentEntryId`; missing fields from old APNs payloads decode as `nil`.
- Completion deep link uses `whatsub://library?id=<entryId>`.

- [ ] **Step 1: Write failing presentation and deep-link tests**

Assert queued/running/progress/quota-paused/failed/completed/cancelled copy,
backward decoding of an old ContentState without `recentEntryId`, and that a
completed deep link selects Library and opens the expected entry through a
bound `NavigationStack` path. When work remains in progress, the widget still
links to `whatsub://import-queue`.

- [ ] **Step 2: Verify RED, implement UI/deep link, verify GREEN**

Use the focused simulator test command for `ManagedAnalysisPresentationTests`.

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Me/ImportQueueView.swift whatsub-mobile/Shared/ImportActivityAttributes.swift whatsub-widget/ImportActivityWidget.swift whatsub-widget/LockScreenCard.swift whatsub-mobile/App/LiveActivityCoordinator.swift whatsub-mobile/App/WhatsubMobileApp.swift whatsub-mobile/App/AppState.swift whatsub-mobile/Library/LibraryView.swift whatsub-mobileTests/ManagedAnalysisPresentationTests.swift
git commit -m "feat: surface background analysis progress"
```

### Task 13: End-to-End Verification and Staged Rollout

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-05-mobile-background-analysis-and-youtube-practice-design.md` only if implementation discovered a factual mismatch.

- [ ] **Step 1: Run complete backend verification**

```powershell
pnpm typecheck
pnpm build
pnpm test
```

Expected: all commands exit 0 with no new warnings.

- [ ] **Step 2: Run complete iOS CI verification**

```bash
xcodegen generate
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  build CODE_SIGNING_REQUIRED=NO
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test
```

Expected: build and all tests pass.

- [ ] **Step 3: Deploy disabled worker backend**

Apply `schema.sql`, deploy the new image with `MOBILE_ANALYSIS_ENABLED=false`,
and smoke-test auth, create/list/get/cancel, old relay, Library list, and old
caption-only sync. Confirm Docker restart count remains zero.

- [ ] **Step 4: Release iOS TestFlight and device-test all three modes**

Test free managed <=20 min with app switching, free managed >20 min rejection,
Pro managed >60 min completion after force-closing the app, BYOK >20 min pause
and resume, quota pause, cancellation, and duplicate submission.

- [ ] **Step 5: Enable one worker, then two**

Set `MOBILE_ANALYSIS_ENABLED=true` and `MOBILE_ANALYSIS_WORKERS=1`; monitor queue,
DB connections, memory, DeepSeek connections, failures, and API latency. Raise to
2 only after one real job completes cleanly. Do not exceed the designed values
without a separate capacity review.

- [ ] **Step 6: Commit documentation**

```powershell
git add README.md
# Add the design spec only if implementation required a factual correction.
git commit -m "docs: record mobile background analysis rollout"
```
