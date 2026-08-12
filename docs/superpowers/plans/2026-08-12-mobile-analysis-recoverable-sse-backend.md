# Recoverable Mobile Analysis SSE — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a durable, replayable SSE stream that publishes each completely parsed mobile-analysis cue while preserving the existing background job, 50-cue atomic settlement, billing, cancellation, retry, and polling behavior.

**Architecture:** PostgreSQL remains the source of truth. Workers append attempt-scoped preview events as JSONL cues become valid, and lifecycle transitions append reset/commit/state events in the same transaction as their durable state change. A single process-wide PostgreSQL listener wakes SSE subscribers; each subscriber always re-reads ordered rows from the event ledger, so `NOTIFY` is only a wake-up signal. The current `/results` endpoint remains the compatibility and recovery path.

**Tech Stack:** TypeScript, Hono, PostgreSQL/pg, Server-Sent Events, Vitest, Docker Compose, nginx.

## Global Constraints

- Work in an isolated backend worktree on branch `codex/mobile-analysis-sse`; preserve untracked user files in the main checkout.
- Follow red-green-refactor for every behavior change. Do not write production code before the named failing test has been observed.
- Keep the existing 50-cue phase as the only billing and durable-result boundary.
- A preview-event write failure may disable previews for that phase, but must not discard otherwise valid complete LLM output. Lease loss, conflicting cue contents, malformed output, and final validation still abort the attempt.
- Never persist a token fragment. A `cue` event represents one complete, schema-valid JSONL cue.
- Keep `/api/library/mobile-analysis/jobs/:id/results` backward compatible.
- Cap SSE connections globally and per account; reaching the cap must reject only the stream, never cancel the analysis job.
- Use one dedicated PostgreSQL `LISTEN` connection per backend process, not one connection per phone.
- Preserve server ownership checks on every job read and stream.
- Commit after each task only when its focused tests are green.

---

## Task 1: Add schema and runtime configuration foundations

**Files:**

- Modify: `schema.sql`
- Modify: `src/lib/mobileAnalysisRuntime.ts`
- Modify: `.env.example`
- Modify: `docker-compose.yml`
- Test: `tests/schema.test.ts`
- Test: `tests/mobile-analysis-runtime.test.ts`
- Test: `tests/env-mapping.test.ts`
- Test: `tests/docker-compose-render.test.ts`

**Produces:** `mobile_analysis_events`, attempt timing columns, SSE admission limits.

- [ ] Add failing schema assertions for an event ledger with a monotonic `BIGSERIAL event_id`, `job_id` cascade foreign key, event metadata, JSON payload, created timestamp, and `(job_id, event_id)` replay index. Assert `mobile_analysis_batches` contains `attempt_started_at` and `processing_ms`.
- [ ] Add a failing schema assertion for an `AFTER INSERT` trigger that calls `pg_notify('mobile_analysis_events', ...)`. The payload must contain only `jobId` and `eventId`; event content stays in PostgreSQL.
- [ ] Add failing runtime tests for defaults `sseConnections = 256`, `sseOwnerConnections = 3`, replay page size `200`, heartbeat `15_000ms`, and event retention `24h`. Verify environment overrides are bounded and per-owner does not exceed global.
- [ ] Run the focused tests and record the expected failures:

  ```powershell
  pnpm vitest run tests/schema.test.ts tests/mobile-analysis-runtime.test.ts tests/env-mapping.test.ts tests/docker-compose-render.test.ts
  ```

- [ ] Add this migration shape idempotently to `schema.sql`:

  ```sql
  ALTER TABLE mobile_analysis_batches
    ADD COLUMN IF NOT EXISTS attempt_started_at BIGINT,
    ADD COLUMN IF NOT EXISTS processing_ms INTEGER;

  CREATE TABLE IF NOT EXISTS mobile_analysis_events (
    event_id BIGSERIAL PRIMARY KEY,
    job_id UUID NOT NULL REFERENCES mobile_analysis_jobs(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    batch_index INTEGER,
    attempt INTEGER,
    cue_index INTEGER,
    payload JSONB NOT NULL,
    created_at BIGINT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS mobile_analysis_events_job_event_idx
    ON mobile_analysis_events(job_id, event_id);
  ```

- [ ] Add an idempotent trigger function whose notification is emitted only when the insert transaction commits.
- [ ] Extend `MobileAnalysisRuntimeConfig` and `mobileAnalysisRuntimeFromEnv` with bounded SSE settings. Render those environment variables in Compose and document them in `.env.example`.
- [ ] Re-run the focused tests until green.
- [ ] Commit:

  ```powershell
  git add schema.sql src/lib/mobileAnalysisRuntime.ts .env.example docker-compose.yml tests/schema.test.ts tests/mobile-analysis-runtime.test.ts tests/env-mapping.test.ts tests/docker-compose-render.test.ts
  git commit -m "feat: add mobile analysis event ledger schema"
  ```

---

## Task 2: Implement event types, ownership-safe replay, and snapshot reads

**Files:**

- Modify: `src/lib/types.ts`
- Modify: `src/lib/db.ts`
- Test: `tests/mobile-analysis-db.test.ts`
- Test: `tests/mobile-analysis-postgres.integration.test.ts`

**Consumes:** schema and runtime foundations from Task 1.

**Produces:** ordered append/replay APIs used by workers and SSE routes.

- [ ] Add failing database tests for these contracts:

  ```ts
  type MobileAnalysisEventType =
    | 'cue'
    | 'batch_reset'
    | 'batch_committed'
    | 'phase'
    | 'job_state';

  interface MobileAnalysisEvent {
    eventId: number;
    jobId: string;
    eventType: MobileAnalysisEventType;
    batchIndex: number | null;
    attempt: number | null;
    cueIndex: number | null;
    payload: unknown;
    createdAt: number;
  }
  ```

  Verify ordering by `event_id`, owner isolation, `afterEventId` exclusivity, page limits, and `hasMore` behavior.
- [ ] Add failing tests for `appendMobileAnalysisCueEvent(claim, cue, now)`: first insert returns `appended`, exact duplicate returns `already_appended`, stale lease returns `lease_lost`, and same identity with different payload returns `conflict`.
- [ ] Add failing tests for a snapshot read that returns job state, durable committed-batch cursor, current in-flight attempt, that attempt's cue events only, and the latest event ID. A cold client must not receive abandoned-attempt previews.
- [ ] Add a real-PostgreSQL integration test for concurrent duplicate appends and transaction visibility. Exactly one content value may win; replay must never contain two different values for the same `(job, batch, attempt, cue)` identity.
- [ ] Run the focused tests and confirm red:

  ```powershell
  pnpm vitest run tests/mobile-analysis-db.test.ts tests/mobile-analysis-postgres.integration.test.ts
  ```

- [ ] Add a partial unique index for cue identity:

  ```sql
  CREATE UNIQUE INDEX IF NOT EXISTS mobile_analysis_events_cue_identity_idx
    ON mobile_analysis_events(job_id, batch_index, attempt, cue_index)
    WHERE event_type = 'cue';
  ```

- [ ] Implement strict row mappers and parameterized queries in `Database`. Ownership is proved by joining `mobile_analysis_jobs.owner_email` before returning any event or snapshot.
- [ ] Keep conflict detection explicit: on uniqueness conflict, read the existing payload and compare normalized JSON. Do not silently accept differing content.
- [ ] Re-run the focused tests until green.
- [ ] Commit:

  ```powershell
  git add schema.sql src/lib/types.ts src/lib/db.ts tests/mobile-analysis-db.test.ts tests/mobile-analysis-postgres.integration.test.ts
  git commit -m "feat: persist replayable mobile analysis events"
  ```

---

## Task 3: Make retry, commit, cancel, and timing transitions atomic with events

**Files:**

- Modify: `src/lib/db.ts`
- Modify: `src/lib/cleanup.ts`
- Test: `tests/mobile-analysis-db.test.ts`
- Test: `tests/mobile-analysis-postgres.integration.test.ts`
- Test: `tests/cleanup.test.ts`

**Consumes:** event append/replay APIs from Task 2.

**Produces:** lifecycle events whose ordering cannot diverge from durable job state.

- [ ] Add failing tests that claiming a batch sets `attempt_started_at`, and successful settlement stores bounded `processing_ms` from active-attempt time rather than queue time.
- [ ] Add failing tests that successful cue-phase settlement inserts `batch_committed` in the same transaction as batch result, job counters, and `llm_usage`. Roll back one and assert all roll back.
- [ ] Add failing tests that retry transition increments the attempt and inserts `batch_reset` atomically. Its payload identifies the abandoned attempt and the next attempt.
- [ ] Add failing tests for `job_state` events on cancel, resume, terminal complete, and terminal failure. Existing completed translations remain untouched when canceling.
- [ ] Add failing cleanup tests: prune event rows older than 24 hours in bounded chunks, while cascading job deletion still removes all events.
- [ ] Run tests and confirm red:

  ```powershell
  pnpm vitest run tests/mobile-analysis-db.test.ts tests/mobile-analysis-postgres.integration.test.ts tests/cleanup.test.ts
  ```

- [ ] Refactor transition methods around a shared transaction client. Use the event row's `event_id` as ordering truth; never synthesize ordering in memory.
- [ ] Compute processing time as:

  ```ts
  const processingMs = Math.max(0, Math.min(MAX_PROCESSING_MS, now - attemptStartedAt));
  ```

  If old rows have no `attempt_started_at`, leave `processing_ms` null rather than using queued duration.
- [ ] Implement cleanup with a bounded CTE/delete so daily maintenance cannot hold a large table lock.
- [ ] Re-run focused tests until green.
- [ ] Commit:

  ```powershell
  git add src/lib/db.ts src/lib/cleanup.ts tests/mobile-analysis-db.test.ts tests/mobile-analysis-postgres.integration.test.ts tests/cleanup.test.ts
  git commit -m "feat: publish atomic mobile analysis lifecycle events"
  ```

---

## Task 4: Parse complete JSONL cues incrementally with backpressure

**Files:**

- Modify: `src/lib/mobileAnalysisParser.ts`
- Test: `tests/mobile-analysis-parser.test.ts`

**Produces:** a shared incremental parser and an awaited upstream text-delta callback.

- [ ] Add failing tests for `CueJsonLineStreamParser`: arbitrary UTF-8/text chunk boundaries, several lines in one delta, blank lines, CRLF, and a final line without trailing newline.
- [ ] Add failing tests proving a cue is emitted only after the full JSON object is complete and passes the same schema checks as `parseCueJsonLines`.
- [ ] Add failing tests for duplicate, missing, out-of-range, and out-of-order cue indices. `finish()` must require the exact submitted phase range.
- [ ] Add a failing test showing `consumeAnalysisSse` awaits an async `onTextDelta`; a second delta must not overtake a blocked first callback.
- [ ] Run parser tests and confirm red:

  ```powershell
  pnpm vitest run tests/mobile-analysis-parser.test.ts
  ```

- [ ] Extend parser options without changing existing callers:

  ```ts
  interface AnalysisParserOptions {
    maxOutputBytes: number;
    requireTerminalUsage: boolean;
    onTextDelta?: (delta: string) => Promise<void>;
  }

  export class CueJsonLineStreamParser {
    push(delta: string): ParsedAnalysisCue[];
    finish(): ParsedAnalysisCue[];
  }
  ```

- [ ] Refactor line validation into a shared function used by both the incremental and whole-output paths. Convert SSE dispatch/line-consumption helpers to async so callback backpressure is real.
- [ ] Preserve current output byte caps, terminal usage requirement, `[DONE]` validation, and error mapping.
- [ ] Run parser tests until green and run all existing LLM parser consumers to catch API regressions.
- [ ] Commit:

  ```powershell
  git add src/lib/mobileAnalysisParser.ts tests/mobile-analysis-parser.test.ts
  git commit -m "feat: parse mobile analysis cues incrementally"
  ```

---

## Task 5: Publish cue previews from workers without weakening durable settlement

**Files:**

- Modify: `src/lib/mobileAnalysisWorker.ts`
- Modify: `src/lib/db.ts`
- Test: `tests/mobile-analysis-worker.test.ts`

**Consumes:** Tasks 2-4.

**Produces:** one ordered `cue` event per valid completed JSONL cue.

- [ ] Add a failing worker test that pauses an upstream response between JSONL cues and observes the first cue event before the upstream phase finishes.
- [ ] Add a failing test that event appends are sequential and bounded: cue N+1 is not appended until cue N's append resolves.
- [ ] Add a failing test that `lease_lost` stops consuming/publishing the attempt and does not settle it.
- [ ] Add a failing test that an exact duplicate append is harmless and a conflicting append fails the attempt.
- [ ] Add a failing test that a transient event-ledger write error disables later preview writes for that phase but still validates and commits a valid whole phase. The final `batch_committed` transition remains authoritative.
- [ ] Add a failing test that malformed final output cannot settle merely because some preview cues were emitted; retry produces a reset event.
- [ ] Run worker tests and confirm red:

  ```powershell
  pnpm vitest run tests/mobile-analysis-worker.test.ts
  ```

- [ ] Wire `CueJsonLineStreamParser` into the cue phase's `onTextDelta`. Await `appendMobileAnalysisCueEvent` for every returned cue.
- [ ] Retain the full response text and call existing whole-phase validation before `settleMobileAnalysisPhase`. Preview success never substitutes for durable settlement.
- [ ] Emit a lightweight `phase` lifecycle event when transitioning from cue generation to summary/finalization if the current pipeline exposes such a phase; otherwise emit only phases already represented by durable batch state.
- [ ] Re-run worker tests until green.
- [ ] Commit:

  ```powershell
  git add src/lib/mobileAnalysisWorker.ts src/lib/db.ts tests/mobile-analysis-worker.test.ts
  git commit -m "feat: stream validated cue previews from workers"
  ```

---

## Task 6: Build the shared PostgreSQL event hub and SSE endpoint

**Files:**

- Create: `src/lib/mobileAnalysisEventHub.ts`
- Create: `src/lib/mobileAnalysisSse.ts`
- Modify: `src/routes/mobileAnalysis.ts`
- Modify: `src/index.ts`
- Test: `tests/mobile-analysis-events.test.ts`
- Test: `tests/mobile-analysis-routes.test.ts`
- Test: `tests/index.test.ts`

**Consumes:** ordered event pages and snapshots from Task 2, runtime limits from Task 1.

**Produces:** `GET /api/library/mobile-analysis/jobs/:id/events`.

- [ ] Add failing event-hub tests proving one dedicated `LISTEN mobile_analysis_events` connection fans wakeups to many local subscribers and reconnects with bounded backoff after connection loss.
- [ ] Add failing admission tests for global cap 256 and per-owner cap 3. A rejected stream returns a retryable response and leaves the job untouched. Closing/aborting a stream always releases its slot.
- [ ] Add failing route tests for authentication, ownership 404, `Last-Event-ID`, query cursor fallback, replay pagination, heartbeat comments, and proper SSE headers.
- [ ] Add a race test for replay-to-live handoff: insert an event after the first page read but before subscription; the stream must still deliver it exactly once by re-reading from the cursor after subscribing.
- [ ] Add a failing cold-snapshot test: with no cursor (or `mode=snapshot`), send `snapshot` first, containing durable progress and only current-attempt previews. Snapshot and `connected` are not persisted ledger rows.
- [ ] Add a failing stale-cursor test that emits `resync` when retained history cannot satisfy the requested cursor, then sends a snapshot.
- [ ] Run tests and confirm red:

  ```powershell
  pnpm vitest run tests/mobile-analysis-events.test.ts tests/mobile-analysis-routes.test.ts tests/index.test.ts
  ```

- [ ] Implement an event hub with this principle:

  ```ts
  // NOTIFY means “something changed”; subscribers then query rows > cursor.
  hub.subscribe(jobId, wake);
  await db.getMobileAnalysisEventsPage(jobId, owner, cursor, 200);
  ```

- [ ] Implement the route using Hono streaming utilities. Send `id:` only for persisted events, `event:` with the event type, one JSON `data:` line, `retry: 3000` on connection, and `: heartbeat` every 15 seconds.
- [ ] Use `Cache-Control: no-cache, no-transform`, `Content-Type: text/event-stream`, `Connection: keep-alive`, and `X-Accel-Buffering: no`.
- [ ] Wire event-hub startup/shutdown in the CLI entrypoint. Tests must prove listener cleanup on server shutdown.
- [ ] Re-run focused tests until green.
- [ ] Commit:

  ```powershell
  git add src/lib/mobileAnalysisEventHub.ts src/lib/mobileAnalysisSse.ts src/routes/mobileAnalysis.ts src/index.ts tests/mobile-analysis-events.test.ts tests/mobile-analysis-routes.test.ts tests/index.test.ts
  git commit -m "feat: expose recoverable mobile analysis SSE"
  ```

---

## Task 7: Expose queue estimates and configure the reverse proxy

**Files:**

- Modify: `src/lib/db.ts`
- Modify: `src/routes/mobileAnalysis.ts`
- Modify: `src/lib/types.ts`
- Modify: `nginx/whatsub.conf`
- Test: `tests/mobile-analysis-db.test.ts`
- Test: `tests/mobile-analysis-routes.test.ts`
- Test: `tests/nginx-config.test.ts`

**Produces:** optional `jobsAhead` and `estimatedStartSeconds`, plus unbuffered production delivery.

- [ ] Add failing DB tests that queue position counts runnable owners ahead under the existing fair ordering, not simply all batches. The current owner's extra batches must not inflate its own ahead count.
- [ ] Add failing tests for ETA based on the median `processing_ms` of the latest 100 completed cue phases. If there is insufficient timing data, return `null` rather than a fabricated ETA.
- [ ] Add route tests proving new queue fields are optional/backward compatible and disappear or become zero after a lease starts.
- [ ] Add an nginx static/config test asserting the longer `/api/library/mobile-analysis/` location disables proxy buffering/compression, forwards immediately, and has a stream-appropriate read timeout while preserving authentication headers.
- [ ] Run focused tests and confirm red:

  ```powershell
  pnpm vitest run tests/mobile-analysis-db.test.ts tests/mobile-analysis-routes.test.ts tests/nginx-config.test.ts
  ```

- [ ] Implement queue estimates as advisory data. Never gate scheduling or billing on the estimate.
- [ ] Add the SSE-specific nginx location before the general `/api/library/` route:

  ```nginx
  location /api/library/mobile-analysis/ {
      proxy_pass http://app;
      proxy_http_version 1.1;
      proxy_buffering off;
      proxy_cache off;
      gzip off;
      proxy_read_timeout 300s;
      add_header X-Accel-Buffering no;
  }
  ```

- [ ] Re-run focused tests until green.
- [ ] Commit:

  ```powershell
  git add src/lib/db.ts src/lib/types.ts src/routes/mobileAnalysis.ts nginx/whatsub.conf tests/mobile-analysis-db.test.ts tests/mobile-analysis-routes.test.ts tests/nginx-config.test.ts
  git commit -m "feat: report mobile analysis queue estimates"
  ```

---

## Task 8: Add pending-submission recovery and complete backend verification

**Files:**

- Modify: `src/routes/mobileAnalysis.ts`
- Modify: `src/lib/db.ts`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Test: `tests/mobile-analysis-routes.test.ts`
- Test: `tests/mobile-analysis-postgres.integration.test.ts`

**Produces:** idempotent retry behavior when the admission queue is temporarily full; operator documentation.

- [ ] Add failing route tests for a stable client idempotency key on job creation. Repeating the same accepted submission returns the existing job; repeating a temporarily rejected submission cannot create duplicates later.
- [ ] Confirm the current schema already has an equivalent request identity. If not, add an owner-scoped `client_request_id` unique column and migration with tests.
- [ ] Add a PostgreSQL integration test for concurrent duplicate creates.
- [ ] Run focused tests and confirm red.
- [ ] Implement only the server half needed by iOS: accept an optional stable request ID, return it in diagnostics, and return a retryable queue-full response without consuming quota.
- [ ] Document event semantics, replay, caps, worker canary guidance (`4 → 6 → 8` only when queue age and health justify it), nginx requirements, and rollback steps. Keep production default workers at 4 for the first deploy.
- [ ] Run complete backend verification:

  ```powershell
  pnpm test
  pnpm typecheck
  pnpm build
  docker compose config
  ```

- [ ] Inspect `git diff --check`, scan for placeholders with `rg "TODO|TBD|FIXME"`, and review migrations for restart/idempotency safety.
- [ ] Commit:

  ```powershell
  git add src/routes/mobileAnalysis.ts src/lib/db.ts schema.sql README.md AGENTS.md tests/mobile-analysis-routes.test.ts tests/mobile-analysis-postgres.integration.test.ts
  git commit -m "feat: make mobile analysis submission recoverable"
  ```

- [ ] Request a code review focused on transaction boundaries, replay races, connection cleanup, and compatibility. Resolve findings with new failing tests before changing implementation.

