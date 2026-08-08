# Mobile Analysis Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a safe diagnostic TestFlight build and matching backend response that identify managed-analysis HTTP 400 causes and BYOK zero-progress stalls from a screenshot.

**Architecture:** The backend classifies validation failures into stable diagnostic codes and returns a correlation ID while logging only bounded metadata. The iOS client builds sanitized managed-request reports and instruments the BYOK stream lifecycle, presenting a copyable report on submission failure or a 90-second zero-progress timeout.

**Tech Stack:** Swift 5.10, SwiftUI, URLSession, XCTest, TypeScript 5.6, Hono, Vitest, Node 20, Docker release scripts, GitHub Actions/TestFlight.

## Global Constraints

- iOS 16+ and no new third-party Swift dependencies.
- Never include subtitle text, prompts, streamed output, API keys, authorization headers, session tokens, email, full URLs, or request JSON in diagnostics.
- Preserve the existing top-level backend `error` field for backward compatibility.
- Successful import UI remains unchanged; diagnostics appear only after failure or timeout.
- Use test-first red-green cycles and small commits in each repository.
- Swift compilation and simulator tests are verified by GitHub Actions because the local host is Windows.

---

### Task 1: Backend field-level validation diagnostics

**Files:**
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/.worktrees/mobile-background-analysis/src/routes/mobileAnalysis.ts`
- Modify: `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license/.worktrees/mobile-background-analysis/tests/mobile-analysis-routes.test.ts`

**Interfaces:**
- Produces: `MobileAnalysisDiagnosticCode`, a closed string union used by validation responses.
- Produces: validation result `{ error, diagnosticCode, metadata }` where metadata contains only numeric/boolean bounded values.
- Preserves: `{ error: "invalid_input" | "duration_unknown" }` for old clients.

- [ ] **Step 1: Write failing route tests for stable reasons and correlation**

Add table-driven tests that submit one invalid request per field and assert responses such as:

```ts
expect(await response.json()).toMatchObject({
  error: 'invalid_input',
  diagnosticCode: 'cue_end_after_duration',
  diagnosticId: expect.stringMatching(/^[a-f0-9]{12}$/),
});
```

Cover `invalid_source_url`, `invalid_thumbnail`, `invalid_cue_index`, `invalid_cue_timing`, `cue_end_after_duration`, and `invalid_transcript`. Inject a log sink into `mobileAnalysisRoute`, capture its object, stringify it, and assert it does not contain fixture subtitle text, email, bearer token, full URL, or request JSON.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
npm test -- tests/mobile-analysis-routes.test.ts
```

Expected: FAIL because `diagnosticCode`, `diagnosticId`, and injectable safe logging do not exist.

- [ ] **Step 3: Implement ordered validation classification**

Change `parseJobInput` to return the first stable field-level reason instead of collapsing every check into one boolean. Add:

```ts
type MobileAnalysisDiagnosticCode =
  | 'invalid_source_url'
  | 'invalid_thumbnail'
  | 'invalid_cue_index'
  | 'invalid_cue_timing'
  | 'cue_end_after_duration'
  | 'invalid_transcript'
  | 'invalid_request_shape';

type DiagnosticLog = (event: Readonly<Record<string, string | number | boolean | null>>) => void;
```

Generate `diagnosticId` from `randomBytes(6).toString('hex')`. Log exactly: event name, diagnostic ID/code, a SHA-256 email hash prefix, body byte count, cue count, duration, final cue end, and decoded thumbnail byte count. Return the diagnostic fields only for 400 input/duration failures.

- [ ] **Step 4: Run route tests and verify GREEN**

Run:

```powershell
npm test -- tests/mobile-analysis-routes.test.ts
npm run typecheck
```

Expected: all focused tests pass and TypeScript reports no errors.

- [ ] **Step 5: Commit backend diagnostics**

```powershell
git add src/routes/mobileAnalysis.ts tests/mobile-analysis-routes.test.ts
git commit -m "feat: classify mobile analysis validation failures"
```

### Task 2: iOS managed-request diagnostic report

**Files:**
- Modify: `whatsub-mobile/Import/ManagedAnalysisModels.swift`
- Modify: `whatsub-mobile/Import/ManagedAnalysisClient.swift`
- Create: `whatsub-mobile/Import/AnalysisDiagnosticReport.swift`
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Test: `whatsub-mobileTests/ManagedAnalysisClientTests.swift`
- Create: `whatsub-mobileTests/AnalysisDiagnosticReportTests.swift`

**Interfaces:**
- Produces: `AnalysisDiagnosticReport` with `category`, `summary`, and `copyText`.
- Produces: `ManagedAnalysisClientError.server(status:code:diagnosticCode:diagnosticId:)`.
- Consumes: `ManagedAnalysisCreateRequest` immediately before submission.

- [ ] **Step 1: Write failing decoding and sanitization tests**

Add a client test returning:

```json
{"error":"invalid_input","diagnosticCode":"invalid_thumbnail","diagnosticId":"abc123def456"}
```

Assert all four associated values survive error mapping. Add report tests constructing a request with sentinel subtitle text, title, API-like string, token-like string, and full URL; assert `copyText` contains status, codes, duration, cue count, final cue end, encoded bytes, thumbnail bytes, video ID, app version/build, and does not contain any sentinel or full URL.

- [ ] **Step 2: Verify the iOS tests are RED in CI-compatible source state**

Since Xcode is unavailable locally, run source-presence checks and commit the failing tests first:

```powershell
rg -n "diagnosticCode|AnalysisDiagnosticReport" whatsub-mobileTests
git diff --check
```

Expected: test sources reference APIs that production code does not yet define. Push only after Task 4 so the normal CI run evaluates the complete red-green result.

- [ ] **Step 3: Implement response decoding and sanitized report generation**

Extend `ManagedAnalysisErrorBody` with optional `diagnosticCode` and `diagnosticId`. Add a report factory with this public shape:

```swift
struct AnalysisDiagnosticReport: Equatable {
    let category: String
    let summary: String
    var copyText: String { summary }

    static func managed(
        request: ManagedAnalysisCreateRequest,
        encodedBytes: Int,
        status: Int,
        code: String?,
        diagnosticCode: String?,
        diagnosticId: String?
    ) -> Self
}
```

Calculate thumbnail bytes from validated Base64 length and use `Bundle.main` version/build with `unknown` fallbacks. Store the report on `ImportViewModel` only when submission fails; clear it at the beginning of every new attempt.

- [ ] **Step 4: Run static checks**

```powershell
git diff --check
rg -n "subtitle sentinel|api-key sentinel|bearer sentinel" whatsub-mobile/Import
```

Expected: no whitespace errors and no test sentinel appears in production source.

- [ ] **Step 5: Commit managed client diagnostics**

```powershell
git add whatsub-mobile/Import/ManagedAnalysisModels.swift whatsub-mobile/Import/ManagedAnalysisClient.swift whatsub-mobile/Import/AnalysisDiagnosticReport.swift whatsub-mobile/Import/ImportViewModel.swift whatsub-mobileTests/ManagedAnalysisClientTests.swift whatsub-mobileTests/AnalysisDiagnosticReportTests.swift
git commit -m "feat: expose managed analysis diagnostics"
```

### Task 3: BYOK stream lifecycle and bounded no-progress timeout

**Files:**
- Create: `whatsub-mobile/LLM/AnalysisStreamDiagnostics.swift`
- Modify: `whatsub-mobile/LLM/ChatCompletionsClient.swift`
- Modify: `whatsub-mobile/LLM/AnalysisEngine.swift`
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Create: `whatsub-mobileTests/AnalysisStreamDiagnosticsTests.swift`
- Modify: `whatsub-mobileTests/AnalysisEngineTests.swift`
- Modify: `whatsub-mobileTests/ImportBYOKResumeTests.swift`

**Interfaces:**
- Produces: `AnalysisStreamStage` cases `preparingRequest`, `connecting`, `responseOpen`, `firstContent`, `parsing`, and `batchComplete`.
- Produces: callback `(AnalysisStreamEvent) -> Void` from transport through engine to view model.
- Produces: injectable `BYOKNoProgressClock` so 90-second behavior is deterministic in tests.

- [ ] **Step 1: Write failing lifecycle and timeout tests**

Test that a stub SSE stream emits stages in monotonic order, that the first parsed cue emits `parsing(parsedCues: 1)`, and that batch validation emits `batchComplete`. In the view-model test, inject an immediate clock representing 90 elapsed seconds and assert a zero-cue run ends in `.error` with a `byok-stream` report whose stage is `connecting`, `response_open`, or `first_content`. Add a second test where progress reaches one cue before the clock fires and assert the timeout is cancelled.

- [ ] **Step 2: Run/check RED state**

```powershell
rg -n "AnalysisStreamStage|BYOKNoProgressClock" whatsub-mobileTests
git diff --check
```

Expected: tests reference missing production types.

- [ ] **Step 3: Implement minimal lifecycle events and timeout race**

Add:

```swift
enum AnalysisStreamStage: String, Codable {
    case preparingRequest = "preparing_request"
    case connecting
    case responseOpen = "response_open"
    case firstContent = "first_content"
    case parsing
    case batchComplete = "batch_complete"
}

struct AnalysisStreamEvent: Equatable {
    let stage: AnalysisStreamStage
    let batch: Int
    let parsedCues: Int
}
```

Emit events at request construction, before `session.bytes`, after a 2xx response, on first non-empty delta, on first/new parsed cue, and after checkpoint persistence. In `ImportViewModel`, race the first-batch analysis against an injected 90-second sleep. Cancel the sleep once parsed progress is greater than zero. Timeout cancellation must cancel the active stream and surface a sanitized report containing category, stage, elapsed seconds, provider host, model, batch, and parsed count only.

- [ ] **Step 4: Verify static consistency**

```powershell
git diff --check
rg -n "Authorization|apiKey|messages|subtitle" whatsub-mobile/LLM/AnalysisStreamDiagnostics.swift
```

Expected: no sensitive fields are stored by the diagnostic type.

- [ ] **Step 5: Commit BYOK diagnostics**

```powershell
git add whatsub-mobile/LLM/AnalysisStreamDiagnostics.swift whatsub-mobile/LLM/ChatCompletionsClient.swift whatsub-mobile/LLM/AnalysisEngine.swift whatsub-mobile/Import/ImportViewModel.swift whatsub-mobileTests/AnalysisStreamDiagnosticsTests.swift whatsub-mobileTests/AnalysisEngineTests.swift whatsub-mobileTests/ImportBYOKResumeTests.swift
git commit -m "feat: diagnose stalled BYOK analysis streams"
```

### Task 4: Copyable diagnostic UI and iOS CI verification

**Files:**
- Create: `whatsub-mobile/Import/AnalysisDiagnosticSheet.swift`
- Modify: `whatsub-mobile/Import/ImportView.swift`
- Modify: `project.yml` only if explicit source lists require the new files
- Modify: `whatsub-mobileTests/AnalysisDiagnosticReportTests.swift`

**Interfaces:**
- Consumes: `ImportViewModel.diagnosticReport: AnalysisDiagnosticReport?`.
- Produces: `复制诊断信息` button and selectable monospaced report sheet.

- [ ] **Step 1: Write the failing presentation assertion**

Add a report presentation test asserting the button title is `复制诊断信息` and a snapshot-safe formatter test asserting line order starts with category and app build, followed by status/stage fields.

- [ ] **Step 2: Verify RED by source inspection**

```powershell
rg -n "复制诊断信息" whatsub-mobile/Import
```

Expected: no match before implementation.

- [ ] **Step 3: Implement the diagnostic sheet**

Render a secondary button only when `diagnosticReport != nil`. The sheet uses `ScrollView`, selectable monospaced `Text`, a system pasteboard copy action, and a close button. Do not add diagnostics to successful/normal states.

- [ ] **Step 4: Push branch and verify GitHub CI**

```powershell
git add whatsub-mobile/Import/AnalysisDiagnosticSheet.swift whatsub-mobile/Import/ImportView.swift project.yml whatsub-mobileTests/AnalysisDiagnosticReportTests.swift
git commit -m "feat: add copyable analysis diagnostic report"
git push -u origin codex/analysis-diagnostics
gh run watch --exit-status
```

Expected: simulator build and XCTest workflow exit 0. If CI fails, inspect the exact compiler/test failure, add a failing regression where possible, fix minimally, and rerun.

### Task 5: Backend verification and production deployment

**Files:**
- No new source files expected.
- Use the canonical release scripts documented by `whatsub-license` rather than ad-hoc Docker commands.

**Interfaces:**
- Requires: Task 1 backend commit.
- Produces: production responses containing diagnostic code/ID for invalid mobile jobs.

- [ ] **Step 1: Run the full backend verification suite**

```powershell
npm test
npm run typecheck
npm run build
```

Expected: all commands exit 0.

- [ ] **Step 2: Push the backend branch**

```powershell
git push origin codex/mobile-background-analysis-backend
```

- [ ] **Step 3: Build, upload, and activate through canonical release scripts**

Run the documented `build-mobile-analysis-release`, upload, and activation commands from the backend README/AGENTS instructions. Record the immutable release ID.

- [ ] **Step 4: Verify production health and compatibility**

Confirm readiness is ready, container state is running/healthy with restart count zero, and an authenticated invalid fixture returns HTTP 400 with `error`, `diagnosticCode`, and `diagnosticId`. Confirm a valid fixture reaches HTTP 202 and creates a job.

### Task 6: Publish diagnostic TestFlight

**Files:**
- Modify version/build metadata only if the workflow does not auto-increment it.

**Interfaces:**
- Requires: healthy backend deployment and green iOS CI.
- Produces: an installable TestFlight build containing both managed and BYOK reports.

- [ ] **Step 1: Merge or push the verified mobile commit to the TestFlight-triggering branch**

Use the repository's current main-branch workflow. Preserve unrelated changes and do not force push.

- [ ] **Step 2: Watch TestFlight upload to completion**

```powershell
gh run watch --exit-status
```

Expected: archive, export, and App Store Connect upload all succeed.

- [ ] **Step 3: Provide reproduction instructions**

Ask for two copied reports:

1. Subscription/managed: import any YouTube video on phone, then tap `复制诊断信息` on the submission error.
2. BYOK: disable managed relay, import any YouTube video, wait for the bounded timeout or error, then tap `复制诊断信息`.

Use those reports plus the matching backend diagnostic ID to identify and implement the actual root-cause fixes in a separate red-green bugfix cycle.
