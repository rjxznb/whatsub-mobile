# Mobile Background Analysis and YouTube Practice — Design

**Date:** 2026-08-05  
**Repositories:** `whatsub-mobile`, `whatsub-license`  
**Status:** Approved product direction; implementation pending

## 1. Problem statement

The current iOS import pipeline is controlled entirely by the phone:

1. iOS fetches YouTube captions.
2. `AnalysisEngine` splits captions into 50-cue batches.
3. iOS opens one managed-relay SSE request per batch.
4. iOS parses and accumulates every batch in memory.
5. iOS uploads the completed analysis to Library.

The model inference already runs at DeepSeek and every managed request already
passes through `whatsub-license`, but the backend does not own the overall job.
Consequently, iOS suspension after switching apps can stop the batch loop, lose
in-memory progress, and make a retry spend tokens on already completed batches.

Production evidence on 2026-08-05 also exposed a separate duration bug. A free
account completed 34 relay requests and consumed 202,802 tokens before receiving
`free_used_up`. Mobile import never supplied `durationSec`, so the existing
20/60-minute cloud-media policy did not protect the AI stage. The UI then offered
both “retry AI” and VPN help even though neither could resolve a quota rejection.

YouTube-only Library entries have another related gap. They have no OSS
`videoUrl` or `audioUrl`; `ShadowSheet` and `ClozeSheet` therefore construct an
empty `CueAudioPlayer`. Their “听原文” control remains visible but cannot emit
audio.

## 2. Goals

- Managed-AI imports continue when the user switches apps, locks the phone, or
  iOS terminates the app.
- Persist every completed AI batch so retries never restart the whole video.
- Keep backend and DeepSeek concurrency strictly bounded.
- Apply the agreed entitlement and duration matrix.
- Keep BYOK credentials on-device while making BYOK parsing resumable.
- Make “听原文” work for VPN-required YouTube entries in both 跟读 and 听抄.
- Preserve the existing OSS/audio-sidecar fast path unchanged.

## 3. Non-goals

- The backend will not download YouTube video or audio for phone imports.
- BYOK keys will never be uploaded to whatSub.
- Product-level unlimited parsing does not remove technical request-size,
  monthly-token, OSS-size, or self-hosted-media limits.
- Existing desktop OSS upload limits are unchanged by this design.
- iOS background execution tricks (background audio, indefinite background
  tasks, or opportunistic `BGProcessingTask`) will not be used to imitate a
  reliable worker.

## 4. Entitlement and execution matrix

| Mode | Orchestrator | Product duration limit | Token budget | App switching |
|---|---|---:|---:|---|
| Free + managed AI | Backend async job | 20 minutes per video | 200K lifetime | Supported |
| Pro + managed AI | Backend async job | No duration limit | 5M per month | Supported |
| BYOK (free or Pro) | iOS foreground pipeline | No duration limit | User's provider | Pauses; resumes from checkpoint |

“No duration limit” means no product-level time cap for caption/AI analysis.
Technical payload and cue-count ceilings remain mandatory to prevent memory and
database abuse. Caption-only Library entries must not be rejected by the OSS
media-duration fence. Desktop/self-hosted video uploads retain their existing
storage limits.

The backend is authoritative:

- A managed job is classified as `pro` only when
  `hasActiveSubscription(email, now)` succeeds at creation time.
- Otherwise it is a free managed job and `durationSec > 1200` is rejected.
- A Pro job accepted while the subscription is active may finish if the
  subscription expires during that job. No new Pro job may be created after
  expiry.
- Free lifetime and Pro monthly token checks run before every batch.

## 5. Duration acquisition and preflight

`YouTubeCaptionExtractor` already receives the Innertube player response before
fetching timed text. It will return a structured result containing captions and
`videoDetails.lengthSeconds` instead of returning only `[Cue]`.

For managed AI:

1. Parse and validate `durationSec` before creating a backend job.
2. Free users over 1,200 seconds see a specific screen offering Pro or BYOK.
3. Pro users are not blocked by duration.
4. Send the same duration to the backend; the backend repeats the free check.
5. Store and later sync the real duration instead of `nil`.

If Innertube omits or malforms the duration, managed analysis does not start.
The UI asks the user to retry instead of allowing an unknown value to bypass the
server fence. BYOK may continue with unknown duration because it incurs no
managed-model cost, but a recovered duration is still synced when available.

## 6. Managed background job architecture

### 6.1 API surface

All endpoints require a valid iOS session token.

- `POST /api/library/mobile-analysis/jobs`
  - Accepts source identity, title, duration, normalized cues/SRT, and an
    idempotency key.
  - Returns `202 { jobId, status, tier }` quickly; it never holds the phone
    connection for model execution.
- `GET /api/library/mobile-analysis/jobs/:id`
  - Returns status, completed/total cues, token usage, failure code, and the
    resulting Library entry ID when complete.
- `POST /api/library/mobile-analysis/jobs/:id/cancel`
  - Marks queued work cancelled. An in-flight batch is allowed to settle, but
    no later batch starts.
- `GET /api/library/mobile-analysis/jobs`
  - Lists the current account's recent jobs so progress survives reinstalling
    the view or relaunching the app.

Creating the same idempotency key twice returns the existing unfinished or
completed job. This prevents share-sheet retries and flaky networks from
duplicating token spend.

### 6.2 Persistence

Use two PostgreSQL tables rather than rewriting one ever-growing JSON document:

- `mobile_analysis_jobs`: identity, owner, source metadata, tier snapshot,
  status, duration, total batches, next scheduling time, lease owner/expiry,
  token totals, result entry ID, cancellation flag, and sanitized error code.
- `mobile_analysis_batches`: `(job_id, batch_index)` primary key, cue range,
  completed result JSON, input/output tokens, attempt count, and completion
  timestamp.

Raw captions are stored once on the job as bounded JSONB or compressed text.
Batch results are immutable after success. Final assembly reads batches in index
order, performs the summary phase once, writes the caption-only Library entry,
and marks the job complete transactionally.

No database connection remains checked out while waiting for DeepSeek. Claim,
save, final assembly, and status transitions each use short transactions.

### 6.3 Leasing and restart recovery

Workers claim work using `FOR UPDATE SKIP LOCKED` and a lease expiry. A claim
sets `lease_owner` and `lease_expires_at`, commits, and releases the connection
before the outbound request starts. A crashed container leaves an expiring
lease; another worker later retries only that unfinished batch.

Successful batch insertion is idempotent by `(job_id, batch_index)`. A late
response from an expired worker cannot overwrite a completed batch.

### 6.4 Fair scheduling

A worker executes one 50-cue batch, persists it, and returns the job to the
scheduler. It does not hold a worker for the full video. Jobs are selected by
eligibility time and least-recently-served order, with at most one in-flight
batch per account. A very long Pro video therefore cannot monopolize a worker.

## 7. Concurrency and overload protection

Production currently has 2 CPU cores, 3.4 GiB RAM, PostgreSQL
`max_connections=100`, and a whatSub pool size of 10. Initial limits are
therefore deliberately conservative:

| Guard | Initial value |
|---|---:|
| Background batch workers | 2 |
| All DeepSeek outbound connections | 4 |
| Background DeepSeek connections | 2 |
| In-flight batches per account | 1 |
| Unfinished jobs per account | 3 |
| Global unfinished job queue | 100 |

The DeepSeek limiter is shared by interactive relay traffic and workers.
Interactive QuickChat/photo/roleplay requests enter the priority lane;
background workers may occupy no more than two of the four global slots. A full
queue fails fast with a retryable `server_busy` response.

Each batch has a 300-second timeout and at most two retries with exponential
backoff and jitter. Repeated upstream failures open a short circuit breaker so
workers stop creating reconnect storms. Queue depth, leases, active outbound
connections, batch latency, DeepSeek 429/5xx rates, and DB pool wait time are
logged as bounded metrics without transcript or email contents.

Limits are environment-controlled but default-safe; absent variables never mean
unbounded concurrency.

## 8. Quota behavior

- Free managed usage is lifetime-summed and capped at 200K tokens.
- Pro managed usage is month-scoped and capped at 5M tokens.
- The worker checks remaining quota before claiming the next model slot.
- Actual usage is recorded from DeepSeek's usage frame after every batch.
- If a job exhausts quota, it becomes `paused_quota` with all completed batches
  retained. It does not spin or retry.
- Retrying after subscription/period refresh resumes at the first unfinished
  batch.
- Cancellation or network failure does not refund a batch already sent to the
  model.

iOS may display an estimate from cue count before submission, but estimates are
informational. Only server-recorded usage is authoritative.

## 9. BYOK foreground checkpointing

BYOK keeps the existing direct provider path because the API key remains in the
iOS Keychain. It gains durable per-batch checkpoints in Application Support:

- A source/caption fingerprint identifies the run.
- Every successful 50-cue batch is atomically persisted.
- Entering background finishes the current batch only while iOS grants normal
  execution time, then stops opening new requests.
- Foregrounding resumes at the first unfinished batch.
- A killed app can resume after relaunch.
- Completed/cancelled checkpoints are removed according to a bounded retention
  policy.

The UI explicitly labels BYOK as “本机解析；切到后台会暂停，回来自动继续”. It
must never imply that iOS can run indefinitely in the background.

## 10. iOS managed-job experience

After captions and duration are known, managed mode submits a job and moves to a
durable progress screen. The import sheet can be dismissed immediately. Recent
jobs appear in the existing import-queue area with queued, parsing, completed,
quota-paused, failed, and cancelled states.

The existing Live Activity/APNs infrastructure reports aggregate progress and
completion. Foreground polling refreshes exact batch progress; the app does not
poll continuously in the background. Completion deep-links to the new Library
entry.

Typed errors drive typed actions:

- `video_too_long`: free 20-minute explanation + Pro/BYOK choices.
- `free_used_up`: subscription/BYOK choices; no VPN action and no blind retry.
- `quota_exceeded`: monthly reset/subscription management; retain progress.
- `server_busy`: retry later without creating a duplicate job.
- `upstream_unavailable`: retain progress and retry from the next batch.
- `duration_unknown`: retry metadata fetch.

The incorrect “本月免费额度” copy is replaced: free is a lifetime experience
pool; only Pro is monthly.

## 11. YouTube original audio in 跟读 and 听抄

OSS-backed entries continue to use `audioUrl`, shared AVPlayer, or `videoUrl` in
that order. YouTube-only entries use an official visible IFrame player inside
the practice sheet.

`LibraryDetailView` passes a validated `youtubeId` to both practice sheets.
Each sheet renders a `YouTubeCuePlayerView` with a viewport at least 200×200,
matching YouTube's required minimum functionality. The player is not hidden or
covered by custom overlays.

The external “听原文” control sends a typed command to the visible player:

1. `seekTo(cue.time, true)`
2. `playVideo()`
3. Observe player time through the existing iOS bridge.
4. `pauseVideo()` at `cue.endTime`.

The parent Library player is paused before presenting practice and is not
automatically resumed afterward. YouTube mode exposes only rates returned by
`getAvailablePlaybackRates` rather than pretending arbitrary AVPlayer rates are
supported. Loading, VPN failure, player error, and unavailable-video states are
visible; no empty AVPlayer-backed button is rendered.

Reference: <https://developers.google.com/youtube/terms/required-minimum-functionality>

## 12. Security and abuse controls

- Session-derived email owns every job; IDs alone never authorize access.
- Validate YouTube IDs, URLs, duration, cue timestamps, cue count, and body size.
- Technical transcript/cue ceilings are sized well above legitimate long-form
  use but remain finite. “Unlimited” never means unbounded request bytes.
- Free duration is checked independently on iOS and backend.
- The worker builds model prompts from validated fields; clients cannot supply
  arbitrary system prompts or model parameters.
- Logs and metrics omit captions, prompts, bearer tokens, BYOK keys, and raw
  email addresses.
- Account deletion cascades jobs and batch data.
- Completed source captions and batch rows have an explicit retention/cleanup
  schedule after final Library assembly.

## 13. Verification strategy

### Backend

- Entitlement matrix: free 20-minute boundary, Pro unlimited duration, BYOK
  endpoint exclusion, expired subscription, and accepted-job completion.
- Idempotent creation and per-account/global queue caps.
- Two-worker concurrency and four-connection global semaphore under races.
- Interactive request priority over background workers.
- `SKIP LOCKED` claims, lease expiry, stale worker response, restart recovery,
  and batch idempotency.
- Quota pause/resume without repeating completed batches.
- Cancellation at queued and in-flight boundaries.
- Caption-only final sync bypasses OSS media-duration policy while media uploads
  retain it.
- Account deletion and cleanup.

### iOS

- Innertube duration decoding and unknown-duration handling.
- Free managed 1,200-second boundary; Pro managed and BYOK unlimited.
- Managed job submission/idempotency/status rendering/deep-link completion.
- BYOK checkpoint resume after background and process recreation.
- Policy errors do not show VPN help or blind AI retry.
- YouTube practice routing, ready/error states, seek/play/end-pause commands,
  available playback rates, and both Shadow/Cloze integration.
- Existing OSS practice playback remains unchanged.

### Production rollout

1. Deploy schema and worker code with claiming disabled.
2. Verify job creation, status, cancellation, auth, and metrics.
3. Release iOS support while the endpoint remains backward-compatible.
4. Enable one worker, observe queue/DB/DeepSeek metrics, then raise to two.
5. Keep the worker feature flag and a rollback image available.

Old iOS builds continue using foreground managed relay calls. The new client
does not silently fall back from a failed managed-job submission to foreground
managed parsing, because that would break the promised background behavior and
could duplicate token spend.
