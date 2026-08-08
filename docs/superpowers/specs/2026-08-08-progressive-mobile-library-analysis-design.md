# Progressive Mobile Library Analysis Design

## Background

The managed mobile-analysis flow currently downloads YouTube captions on iOS,
submits the complete transcript to the backend, and creates a Library entry only
after every cue batch and the final summary have completed. This makes background
execution reliable, but it leaves the user outside the learning experience while
the server works even though the YouTube video and complete English transcript are
already available.

The desktop client separates durable analysis checkpoints from an in-flight
preview. Valid generated cues become visible as they arrive, while a complete
batch is atomically committed before its checkpoint advances. The mobile flow
should preserve the same correctness principle, with PostgreSQL as the durable
owner because iOS may suspend immediately after the user switches apps.

## Goals

1. Create a usable Library card immediately after caption extraction and server
   acceptance.
2. Navigate directly from import into the video detail screen, where the YouTube
   embed and the full English transcript are usable immediately.
3. Reveal Chinese translations and annotations incrementally as durable server
   batches finish.
4. Continue managed analysis after iOS is suspended, with progress recoverable on
   another launch or device.
5. Keep an English-only Library entry after cancellation or terminal failure and
   allow the user to resume analysis.
6. Avoid rewriting the full Library payload or invalidating the Library-list
   cache for every completed batch.
7. Preserve the existing server queue, per-owner concurrency, global concurrency,
   quota accounting, leases, retries, and final validation fences.

## Non-goals

- Do not keep a long-lived SSE or WebSocket connection for correctness.
- Do not make BYOK work continue while iOS is suspended.
- Do not persist unvalidated model output in `library_entries`.
- Do not replace the existing Import Queue or Live Activity in the first version.
- Do not change YouTube playback requirements; the embedded player may still
  require the user's VPN/routing configuration.

## Chosen architecture

Use a provisional Library entry plus durable incremental batch reads.

At managed-job creation, the backend creates both the job and its Library entry
in the same database transaction. The entry ID is the job UUID, which is already
the deterministic ID used by finalization today. Its initial `analysis_json`
contains every authoritative cue with English text and timestamps, empty Chinese
translation/annotation fields, and no key-phrase summary. The job's
`result_entry_id` is set immediately.

Completed cue batches remain authoritative in `mobile_analysis_batches`. They are
not copied into `library_entries` after each batch. A new authenticated incremental
result endpoint exposes only completed, validated batches after a caller-provided
batch cursor. iOS overlays those results onto the English transcript in memory.
When all cue batches and the summary are complete, the existing finalization
transaction revalidates all persisted results and atomically replaces the
provisional `analysis_json` with the final payload.

This mirrors the desktop split:

- Provisional Library payload: stable, durable English baseline.
- Completed server batches: durable progressive overlay.
- Final Library payload: fully validated committed result.

Unlike the desktop's current-batch ephemeral preview, mobile exposes only batches
that have completed and committed on the server. A malformed or interrupted
current batch therefore never appears and never needs to be rolled back on iOS.

## Backend data flow

### Job creation

`POST /api/mobile-analysis/jobs` performs the following in its existing guarded
creation transaction:

1. Validate authentication, source identity, duration, cues, SRT, thumbnail,
   queue limits, and idempotency as today.
2. Insert `mobile_analysis_jobs` and `mobile_analysis_batches` as today.
3. Insert a provisional `library_entries` row with ID equal to the job ID.
4. Set `mobile_analysis_jobs.result_entry_id` to that ID immediately.
5. Commit all rows together and return the normal public job view, now with a
   non-null `resultEntryId`.

An idempotent replay returns the same job and entry. A deterministic ID owned by a
different account is a terminal collision and rolls back creation; ownership is
never transferred.

Creating the provisional row changes the Library version fingerprint once, so the
new card becomes visible to all clients.

### Incremental results

Add an authenticated endpoint shaped like:

`GET /api/mobile-analysis/jobs/:id/results?afterBatch=-1`

The response contains:

```json
{
  "jobId": "uuid",
  "entryId": "uuid",
  "status": "running",
  "completedCues": 100,
  "totalCues": 620,
  "nextBatchCursor": 1,
  "batches": [
    { "batchIndex": 0, "subtitles": [] },
    { "batchIndex": 1, "subtitles": [] }
  ],
  "errorCode": null
}
```

Only rows with `phase = 'cues'` and non-null `completed_at` are returned. Results
are ordered by `batch_index`; ownership is checked through the job. The endpoint
reuses the persisted-batch validator before returning data, so corrupt database
payloads cannot enter the client overlay. The cursor is monotonic and lets iOS
request only newly completed batches.

Polling uses a short interval only while the detail screen is visible. It backs
off when queued and stops in terminal states. The existing job endpoint and Live
Activity remain responsible for background progress when the detail is not open.

### Batch completion and finalization

The worker continues to process at most 50 cues per upstream request and writes
each successful batch through the current lease-fenced transaction. It does not
rewrite `library_entries` for cue batches.

Finalization continues to:

1. Re-read and validate every persisted cue batch.
2. Validate the summary separately.
3. Atomically replace the provisional entry's `analysis_json` with the complete
   payload and bump `synced_at` once.
4. Mark the job completed and publish the existing Live Activity completion
   update with `recentEntryId`.

The Library version therefore changes at most twice: provisional creation and
final completion.

### Cancellation, failure, and deletion

Cancellation and terminal analysis failure leave the provisional Library row in
place. It remains a valid English-caption learning item. The job status supplies
the UI label and retry action.

Resuming reuses the same job, batches, entry ID, and existing durable progress.
It never creates a duplicate card.

Deleting the Library entry while its managed job is active must atomically cancel
the job (or mark cancellation requested) before deleting the row. A stale worker
lease must then fail its existing active-claim fence and cannot recreate the
entry. Deleting an already terminal entry may keep the historical scrubbed job or
remove it according to the existing retention policy, but it must not make the
card reappear.

## iOS data and navigation flow

### Import submission

Caption extraction remains on iOS. As soon as managed job creation returns:

1. Start/update the existing Live Activity.
2. Insert or refresh the provisional item in the Library cache.
3. Dismiss the import sheet.
4. Route through the existing `pendingLibraryEntryID` mechanism to the new entry.

If navigation races the Library fetch, the app loads the detail directly by the
returned entry ID rather than requiring the list refresh to finish first.

### Detail presentation

`LibraryDetailViewModel` loads the provisional entry first. The existing
`analysisJson.subtitles` array supplies the complete English timeline, so the
YouTube embed, subtitle seeking, and English original playback are available
immediately.

For an active managed job, the view model starts incremental polling and keeps:

- the stable baseline subtitles;
- a batch cursor;
- a dictionary of analyzed subtitles keyed by authoritative cue index;
- job status and completed/total cue counts.

Visible rows merge the generated fields over the authoritative baseline. English
text, timestamps, ordering, and identity always come from the baseline. A batch
arrival updates only its matching rows, so playback position and scroll identity
do not jump.

The header shows compact progress such as `AI 解析中 · 150/620`. An unresolved row
shows English normally and a subdued `等待 AI` marker instead of an empty Chinese
line. A resolved row reveals Chinese translation and highlight annotations with a
short, non-layout-disruptive transition.

On completion, the view model performs one normal detail reload, discards the
overlay, and uses the final Library payload as the sole source of truth.

### Library card state

The Library list overlays active managed-job state from the already available job
list rather than changing the Library list/version contract for every batch. A
matching `resultEntryId` adds one of these compact states:

- `AI 解析中 · 150/620`
- `等待服务器`
- `仅英文 · 解析已暂停`
- `仅英文 · AI 解析失败`

Completed jobs add no badge. Tapping a failed/paused card still opens the usable
English transcript; the detail screen offers `继续 AI 解析`.

## BYOK behavior

BYOK remains client-only and unlimited-length according to the existing product
policy. It can adopt the same immediate English baseline and progressive rows
while the app is active, but iOS suspension pauses generation. Its local
checkpoint is restored when the user returns. It must not enqueue managed work,
consume server-managed tokens, or imply that analysis continues in the
background.

The UI must state the distinction clearly:

- Managed entitlement: `可切换 App，服务器继续解析`.
- BYOK: `离开 App 后暂停，返回时继续`.

## Cache and load control

- Do not bump `library_entries.synced_at` per completed cue batch.
- Do not refresh the whole Library list on the detail polling interval.
- Incremental result reads return only batches after the cursor.
- Poll only while a relevant screen is visible; use the existing Live Activity
  and queue view elsewhere.
- Preserve current per-owner and global job concurrency. This feature changes
  read traffic, not model concurrency.
- Add a small randomized polling jitter and server-side request throttling per
  session/job to avoid synchronized clients after notifications.
- Stop polling on completed, failed, or cancelled status and on view disappear.

## Failure handling

- Caption extraction failure: no provisional card, because there is no usable
  English transcript.
- Job creation transaction failure: no partial job or orphan Library row.
- Incremental endpoint failure: keep the last visible English/translated state,
  back off, and retry; video playback remains usable.
- Model batch failure with retries remaining: keep previous durable batches and
  display retrying/queued state.
- Terminal model failure or cancellation: keep the card and English subtitles;
  expose resume.
- Finalization failure: keep the provisional card plus all durable batches; do
  not publish completion. A safe retry can re-run finalization without model
  calls when all generated data is already present.

## Testing

Backend tests must cover:

1. Job and provisional entry are created atomically.
2. Idempotent replay returns the same non-null entry ID without a duplicate card.
3. Provisional subtitles preserve authoritative cue text/timestamps and contain
   no generated fields.
4. Incremental reads return only owned, completed, validated batches after the
   cursor in order.
5. Partial batches do not change the Library version fingerprint.
6. Finalization replaces the same row and changes the fingerprint once.
7. Cancellation/failure preserves the provisional row.
8. Resume keeps the same entry and completed batches.
9. Deleting an active provisional entry prevents stale workers from recreating
   it.
10. Queue and worker concurrency limits remain unchanged.

iOS tests must cover:

1. A successful managed submission navigates directly to the returned entry.
2. English subtitles render before any analyzed batch exists.
3. New batches merge by cue index without changing English/timing or duplicating
   rows.
4. Polling sends the last cursor, stops on terminal state/disappear, and backs off
   after errors.
5. Completion reloads the final detail and removes the overlay.
6. Failure/cancellation keeps the card and exposes resume.
7. Library cache remains stable during partial progress.
8. BYOK clearly pauses on suspension and never calls managed-analysis endpoints.

## Rollout

Deploy the backend compatibility changes first. Older iOS clients will simply see
the provisional English-only Library card and later receive the final payload; the
existing job response tolerates a non-null `resultEntryId`. Release the new iOS
client after backend health checks. No database backfill is required for already
completed jobs. Active pre-deployment jobs may continue using the old
completion-only behavior.

The rollout should initially retain the Import Queue as a diagnostic and recovery
surface. Once telemetry and user testing confirm direct Library progress is
reliable, duplicate status text can be reduced without removing the queue itself.
