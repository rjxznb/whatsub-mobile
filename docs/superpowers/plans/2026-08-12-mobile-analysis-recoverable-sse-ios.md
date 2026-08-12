# Recoverable Mobile Analysis SSE — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each newly analyzed subtitle cue immediately in the Library player, recover correctly across stream loss and app backgrounding, and retain polling as a safe fallback.

**Architecture:** The iOS client first hydrates durable 50-cue results, then opens the authenticated event stream. A pure incremental SSE parser produces typed events. An attempt-aware reducer overlays uncommitted cue previews without replacing baseline English or committed translations. Backgrounding cancels only the HTTP stream; the server job continues. Foreground reconnect uses the in-memory event cursor, while cold launch requests a server snapshot because cursor-only persistence would be unsafe without persisting matching preview state.

**Tech Stack:** Swift 5.10, SwiftUI, URLSession async bytes, XCTest, iOS 16+.

## Global Constraints

- Work in `C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-mobile\.worktrees\mobile-analysis-sse` on `codex/mobile-analysis-sse`.
- Backend event protocol from the backend plan is the consumed contract. Do not invent a second wire format.
- Use TDD. Since Windows cannot run Xcode, push focused red and green commits to the feature branch and use GitHub Actions simulator tests as evidence.
- Preserve existing polling, cancel/resume, free/Pro/BYOK rules, and durable 50-cue merge behavior.
- Do not persist `Last-Event-ID` alone. A cold process requests a snapshot after loading durable `/results`.
- Preview identity is `(batchIndex, attempt, cueIndex)`; a reset removes only the abandoned attempt's previews.
- A committed batch always supersedes its previews. Existing English cues remain playable at all times.
- Scene backgrounding closes only the stream. It must not cancel or pause the backend job.
- Retry network errors with bounded backoff and fall back to polling after three consecutive stream failures.
- Commit each task only after its focused CI evidence is green.

---

## Task 1: Add wire models and a pure incremental SSE parser

**Files:**

- Modify: `whatsub-mobile/Import/ManagedAnalysisModels.swift`
- Create: `whatsub-mobile/Import/ManagedAnalysisSSEParser.swift`
- Create: `whatsub-mobileTests/ManagedAnalysisSSEParserTests.swift`

**Consumes:** backend events `connected`, `snapshot`, `cue`, `batch_reset`, `batch_committed`, `phase`, `job_state`, `resync`.

**Produces:** typed `ManagedAnalysisStreamEvent` values independent of URLSession.

- [ ] Add failing tests for arbitrary byte boundaries, split UTF-8 scalars, CRLF, comment/heartbeat lines, blank event delimiters, `retry:`, `id:`, named events, and several events in one chunk.
- [ ] Add failing tests for multi-line `data:` concatenation and malformed JSON. Malformed payloads must produce a typed parse error, not crash or silently advance the cursor.
- [ ] Add decoding tests for every backend event and for unknown event names. Unknown events are ignored safely without corrupting the last valid event ID.
- [ ] Add compatibility tests for optional queue fields `jobsAhead` and `estimatedStartSeconds` in job responses.
- [ ] Push the failing tests and verify the feature-branch CI fails for the intended missing parser/types.
- [ ] Implement a pure parser with no URLSession dependency:

  ```swift
  struct ManagedAnalysisSSEMessage: Equatable {
      let id: Int64?
      let event: String?
      let data: String
      let retryMilliseconds: Int?
  }

  struct ManagedAnalysisSSEParser {
      mutating func push(_ bytes: Data) throws -> [ManagedAnalysisSSEMessage]
      mutating func finish() throws -> [ManagedAnalysisSSEMessage]
  }
  ```

- [ ] Define explicit Codable payloads and a typed enum. Keep `connected` and `snapshot` ID-less; persisted events carry the server event ID.
- [ ] Push implementation and verify focused tests are green in CI.
- [ ] Commit:

  ```powershell
  git add whatsub-mobile/Import/ManagedAnalysisModels.swift whatsub-mobile/Import/ManagedAnalysisSSEParser.swift whatsub-mobileTests/ManagedAnalysisSSEParserTests.swift
  git commit -m "feat: parse mobile analysis SSE events"
  ```

---

## Task 2: Stream authenticated events from `ManagedAnalysisClient`

**Files:**

- Modify: `whatsub-mobile/Import/ManagedAnalysisClient.swift`
- Modify: `whatsub-mobile/Import/ManagedAnalysisModels.swift`
- Modify: `whatsub-mobileTests/ManagedAnalysisClientTests.swift`

**Consumes:** pure parser from Task 1.

**Produces:** a cancelable `AsyncThrowingStream<ManagedAnalysisStreamEvent, Error>`.

- [ ] Add failing tests that the request path is `/api/library/mobile-analysis/jobs/{escaped-id}/events`, uses `Accept: text/event-stream`, sends bearer auth, and sends `Last-Event-ID` only when reconnecting in the same process.
- [ ] Add failing tests that a cold call uses `mode=snapshot`; an in-memory reconnect uses `mode=replay` and its last event ID.
- [ ] Add failing tests for 401/403/404, 409 terminal conflict if used by the backend, 429/503 stream saturation, non-SSE content type, malformed events, normal EOF, and task cancellation.
- [ ] Add a failing test proving cancellation closes the underlying URLSession task and finishes the async stream exactly once.
- [ ] Push the failing tests and observe the intended CI failure.
- [ ] Extend the protocol:

  ```swift
  protocol ManagedAnalysisClientProtocol {
      // existing buffered methods remain
      func events(
          id: UUID,
          afterEventID: Int64?,
          mode: ManagedAnalysisStreamMode,
          token: String
      ) -> AsyncThrowingStream<ManagedAnalysisStreamEvent, Error>
  }
  ```

- [ ] Add an injectable streaming transport/session abstraction so tests do not open real sockets. Feed URLSession bytes incrementally into `ManagedAnalysisSSEParser` and decode complete messages only.
- [ ] Map stream-admission rejection to a retryable client error distinct from job failure.
- [ ] Push implementation and verify tests green in CI.
- [ ] Commit:

  ```powershell
  git add whatsub-mobile/Import/ManagedAnalysisClient.swift whatsub-mobile/Import/ManagedAnalysisModels.swift whatsub-mobileTests/ManagedAnalysisClientTests.swift
  git commit -m "feat: connect to mobile analysis event stream"
  ```

---

## Task 3: Build an attempt-aware preview reducer

**Files:**

- Modify: `whatsub-mobile/Import/ProgressiveAnalysisOverlay.swift`
- Create: `whatsub-mobile/Import/ManagedAnalysisStreamState.swift`
- Modify: `whatsub-mobileTests/ProgressiveAnalysisOverlayTests.swift`
- Create: `whatsub-mobileTests/ManagedAnalysisStreamStateTests.swift`

**Consumes:** typed events from Task 1 and durable result batches from the existing client.

**Produces:** deterministic render state and progress counts.

- [ ] Add failing reducer tests for cue deduplication, out-of-order replay, current-attempt replacement after `batch_reset`, durable takeover after `batch_committed`, and ignoring stale-attempt cues.
- [ ] Add failing snapshot tests: applying a cold snapshot after durable hydration includes only the server-declared current attempt and starts from the snapshot's latest event ID.
- [ ] Add failing resync tests: clear only uncommitted previews, rehydrate durable results, then apply the new snapshot.
- [ ] Add failing progress tests showing the displayed count is the union of committed cue indices and current valid previews, never a sum that double-counts a committed preview.
- [ ] Add failing tests that English cue text/order/timestamps cannot be overwritten by stream payloads. Only analysis fields are overlaid.
- [ ] Push red tests and observe the intended CI failure.
- [ ] Implement state with explicit identities:

  ```swift
  struct ManagedAnalysisPreviewKey: Hashable {
      let batchIndex: Int
      let attempt: Int
      let cueIndex: Int
  }

  struct ManagedAnalysisStreamState {
      private(set) var lastEventID: Int64?
      mutating func apply(_ event: ManagedAnalysisStreamEvent)
      mutating func applyDurable(_ results: ManagedAnalysisResultsResponse)
      mutating func resetForColdSnapshot()
  }
  ```

- [ ] Keep durable and preview layers separate inside `ProgressiveAnalysisOverlay`; render lookup chooses durable first, then current preview, then baseline.
- [ ] Push implementation and verify reducer/overlay tests green.
- [ ] Commit:

  ```powershell
  git add whatsub-mobile/Import/ProgressiveAnalysisOverlay.swift whatsub-mobile/Import/ManagedAnalysisStreamState.swift whatsub-mobileTests/ProgressiveAnalysisOverlayTests.swift whatsub-mobileTests/ManagedAnalysisStreamStateTests.swift
  git commit -m "feat: reduce recoverable analysis preview events"
  ```

---

## Task 4: Replace foreground polling with stream-first lifecycle management

**Files:**

- Modify: `whatsub-mobile/Views/LibraryDetailViewModel.swift`
- Modify: `whatsub-mobile/Views/LibraryDetailView.swift`
- Modify: `whatsub-mobileTests/LibraryManagedAnalysisTests.swift`

**Consumes:** streaming client and reducer from Tasks 2-3.

**Produces:** immediate cue-by-cue UI with safe reconnect and polling fallback.

- [ ] Add failing view-model tests that initial load hydrates all durable result pages before opening a cold snapshot stream.
- [ ] Add a failing test that each `cue` event updates published cue rows immediately without waiting for `batch_committed`.
- [ ] Add failing tests for `batch_reset`, `batch_committed`, terminal completion, terminal failure, and server-side cancellation.
- [ ] Add failing lifecycle tests: background cancels only the stream task; foreground reconnect uses the in-memory cursor; a new view-model/process does not reuse an unpaired persisted cursor.
- [ ] Add failing retry tests for delays `1, 2, 4, 8, 15` seconds (capped), reset after a healthy event, and polling fallback after three consecutive stream failures. Inject a clock/sleeper so tests are deterministic.
- [ ] Add a failing test that a stream-cap 429/503 switches to polling without marking analysis failed or canceling the job, then retries streaming after 30 seconds or the next foreground transition.
- [ ] Keep an existing polling regression test proving old servers without the endpoint still finish analysis correctly.
- [ ] Push red tests and inspect the intended failure in CI.
- [ ] Refactor `runManagedProgress` into a stream-first coordinator. A representative state transition is:

  ```swift
  for try await event in client.events(
      id: job.id,
      afterEventID: streamState.lastEventID,
      mode: streamState.lastEventID == nil ? .snapshot : .replay,
      token: token
  ) {
      streamState.apply(event)
      publishOverlay()
  }
  ```

- [ ] On `batch_committed`, fetch durable `/results` from the current batch cursor before removing the corresponding preview. On terminal complete, perform one final job/results refresh.
- [ ] Wire `scenePhase` so backgrounding cancels the coordinator's stream task but does not call cancel/resume endpoints.
- [ ] Push implementation and verify tests green.
- [ ] Commit:

  ```powershell
  git add whatsub-mobile/Views/LibraryDetailViewModel.swift whatsub-mobile/Views/LibraryDetailView.swift whatsub-mobileTests/LibraryManagedAnalysisTests.swift
  git commit -m "feat: render managed analysis from SSE"
  ```

---

## Task 5: Present queue state without noisy or misleading UI

**Files:**

- Modify: `whatsub-mobile/Views/LibraryDetailView.swift`
- Modify: `whatsub-mobile/Views/LibraryDetailViewModel.swift`
- Modify: `whatsub-mobileTests/LibraryManagedAnalysisTests.swift`

**Produces:** queue-ahead and ETA copy while preserving the existing animated sparkle/progress UI.

- [ ] Add failing presentation-state tests for: no estimate, zero jobs ahead, one job ahead, multiple jobs ahead, active processing, reconnecting, and polling fallback.
- [ ] Ensure ETA is rounded conservatively (for example, whole minutes) and is always labeled as an estimate. Never display `0 分钟` for a positive wait.
- [ ] Push red tests and confirm the intended failure.
- [ ] Add compact copy below the existing status line, such as `前面还有 2 个任务，预计约 1 分钟开始`. Hide it immediately after processing begins.
- [ ] Preserve the current animated sparkle and stop button. Do not add another large card or modal.
- [ ] Add accessibility labels that distinguish `排队中`, `服务器解析中`, `重新连接中`, and `轮询恢复中`.
- [ ] Push implementation and verify tests green.
- [ ] Commit:

  ```powershell
  git add whatsub-mobile/Views/LibraryDetailView.swift whatsub-mobile/Views/LibraryDetailViewModel.swift whatsub-mobileTests/LibraryManagedAnalysisTests.swift
  git commit -m "feat: show managed analysis queue progress"
  ```

---

## Task 6: Persist temporarily rejected submissions for automatic retry

**Files:**

- Create: `whatsub-mobile/Import/PendingManagedAnalysisStore.swift`
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Modify: `whatsub-mobile/Import/ImportView.swift`
- Create: `whatsub-mobileTests/PendingManagedAnalysisStoreTests.swift`
- Modify: `whatsub-mobileTests/ImportManagedAnalysisTests.swift`

**Consumes:** backend owner-scoped idempotency key and retryable queue-full response.

**Produces:** local, bounded retry for accepted user intent when server admission is temporarily full.

- [ ] Add failing store tests for atomic persistence, file protection, max-entry bound, expiry, stable request ID, deduplication, successful removal, and malformed-file recovery.
- [ ] Add failing import tests that only retryable queue saturation is persisted. Authentication, quota, validation, duration, and permanent errors remain immediate user-visible failures.
- [ ] Add failing tests that foreground/app launch retries pending submissions with bounded backoff and the same request ID, and creates at most one server job.
- [ ] Add a failing test that a successful delayed submission routes to the same Library entry/job status flow as an immediate submission.
- [ ] Push red tests and observe expected CI failure.
- [ ] Implement the store as an actor using an application-support JSON file and `.completeUntilFirstUserAuthentication` protection. Store only the minimum request metadata needed to resubmit; do not store API keys or auth tokens.
- [ ] Keep at most 10 pending submissions and expire entries after 24 hours. Surface one quiet status row, not repeated alerts.
- [ ] Push implementation and verify tests green.
- [ ] Commit:

  ```powershell
  git add whatsub-mobile/Import/PendingManagedAnalysisStore.swift whatsub-mobile/Import/ImportViewModel.swift whatsub-mobile/Import/ImportView.swift whatsub-mobileTests/PendingManagedAnalysisStoreTests.swift whatsub-mobileTests/ImportManagedAnalysisTests.swift
  git commit -m "feat: retry saturated managed analysis submissions"
  ```

---

## Task 7: Complete iOS verification and release readiness

**Files:**

- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/superpowers/specs/2026-08-12-mobile-analysis-recoverable-sse-design.md` only if implementation revealed an approved protocol clarification

- [ ] Run a full feature-branch CI build and all unit tests. Record the workflow URL and exact commit SHA.
- [ ] Add an integration-style fixture test that replays: connect → two cue events → disconnect → replay duplicate cue → batch reset → new attempt cues → batch commit → terminal complete. Assert final UI has no duplicates or stale attempt data.
- [ ] Add a compatibility fixture for a backend that returns 404 on `/events`; verify polling completes the same job.
- [ ] Verify cancellation while streaming, background/foreground reconnection, Network Link Conditioner-style disconnects, and a Library reopen after process kill.
- [ ] Run formatting/static checks available in CI and inspect `git diff --check`.
- [ ] Scan for placeholders and debug output:

  ```powershell
  rg "TODO|TBD|FIXME|print\(" whatsub-mobile whatsub-mobileTests
  ```

- [ ] Update architecture docs with the final event/recovery flow and operational fallback. Do not claim TestFlight release until the workflow upload succeeds.
- [ ] Commit documentation and final fixtures:

  ```powershell
  git add README.md AGENTS.md docs/superpowers/specs/2026-08-12-mobile-analysis-recoverable-sse-design.md whatsub-mobileTests
  git commit -m "docs: document recoverable mobile analysis streaming"
  ```

- [ ] Request code review focused on actor isolation, task cancellation, cursor correctness, reducer idempotency, and iOS 16 URLSession behavior. Resolve every actionable finding with a regression test.

