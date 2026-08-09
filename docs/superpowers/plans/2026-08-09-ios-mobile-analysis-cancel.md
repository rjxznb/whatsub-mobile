# iOS Mobile Analysis Stop Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a confirmed “停止解析” action to the Library detail progress banner while preserving completed subtitle batches and allowing a later resume.

**Architecture:** Reuse the existing managed-analysis `cancel` and `resume` endpoints. `LibraryDetailViewModel` owns cancellation state, race recovery, polling shutdown, and error presentation; `LibraryDetailView` owns only the compact action button and confirmation dialog. The existing `ProgressiveAnalysisOverlay` remains untouched so already merged translations survive cancellation.

**Tech Stack:** Swift 5.10, SwiftUI, async/await, URLSession-backed `ManagedAnalysisClientProtocol`, XCTest, XcodeGen, GitHub Actions/TestFlight.

## Global Constraints

- iOS 16+ and SwiftUI native; add no third-party Swift dependency.
- Show the stop action only for `queued` and `running` jobs.
- Require a confirmation dialog before sending the cancel request.
- Never delete the provisional Library entry or clear completed subtitle batches.
- A successful stop must expose the existing resume action and resume only unfinished server batches.
- Keep `MARKETING_VERSION` at `1.0.2`; the TestFlight workflow assigns a unique `CURRENT_PROJECT_VERSION` from `github.run_number + 100`.
- Do not change the backend API for this feature.

---

## File Structure

- Modify `whatsub-mobile/Library/ProgressiveAnalysisOverlay.swift`: expose compact cancellation capability and accurate cancelled labels.
- Modify `whatsub-mobile/Library/LibraryDetailViewModel.swift`: own `managedCancelling` and the cancel/race-recovery operation.
- Modify `whatsub-mobile/Library/LibraryDetailView.swift`: render the stop action and confirmation dialog.
- Modify `whatsub-mobileTests/LibraryManagedAnalysisTests.swift`: cover success, failure, race recovery, and subtitle preservation.
- Modify `whatsub-mobileTests/ManagedAnalysisPresentationTests.swift`: cover stop/resume capability and cancelled labels.

### Task 1: Cancellation State and ViewModel Operation

**Files:**
- Modify: `whatsub-mobile/Library/ProgressiveAnalysisOverlay.swift`
- Modify: `whatsub-mobile/Library/LibraryDetailViewModel.swift`
- Test: `whatsub-mobileTests/LibraryManagedAnalysisTests.swift`
- Test: `whatsub-mobileTests/ManagedAnalysisPresentationTests.swift`

**Interfaces:**
- Consumes: `ManagedAnalysisClientProtocol.cancel(id:token:)`, `ManagedAnalysisClientProtocol.job(id:token:)`, `ManagedAnalysisProgressState`, and the existing `reloadFinalEntry(id:token:)` helper.
- Produces: `ManagedAnalysisProgressState.canCancel: Bool`, accurate `label` values for cancelled jobs, `LibraryDetailViewModel.managedCancelling: Bool`, and `cancelManagedAnalysis(token:) async`.

- [ ] **Step 1: Extend the managed-analysis test double and write failing ViewModel tests**

Update the `API` actor in `LibraryManagedAnalysisTests.swift` so cancellation can return a chosen job or throw a chosen error, and so calls are observable. Add these stored properties and initializer parameters (all existing call sites continue compiling because the new parameters have defaults):

```swift
private var cancelError: ManagedAnalysisClientError?
private var cancelResponse: ManagedAnalysisJob?
private var jobQueue: [ManagedAnalysisJob]
private(set) var cancelledJobIDs: [String] = []

init(
    details: [LibraryEntryDetail],
    jobs: [ManagedAnalysisJob],
    results: [ManagedAnalysisResultsPage],
    failingDetailCalls: Set<Int> = [],
    cancelResponse: ManagedAnalysisJob? = nil,
    cancelError: ManagedAnalysisClientError? = nil,
    jobResponses: [ManagedAnalysisJob] = []
) {
    detailQueue = details
    listedJobs = jobs
    resultQueue = results
    self.failingDetailCalls = failingDetailCalls
    self.cancelResponse = cancelResponse
    self.cancelError = cancelError
    jobQueue = jobResponses
}

func cancelCalls() -> [String] { cancelledJobIDs }

func cancel(id: String, token: String) async throws -> ManagedAnalysisJob {
    cancelledJobIDs.append(id)
    if let cancelError { throw cancelError }
    guard let cancelResponse else {
        throw ManagedAnalysisClientError.invalidResponse("missing cancel response")
    }
    return cancelResponse
}

func job(id: String, token: String) async throws -> ManagedAnalysisJob {
    if !jobQueue.isEmpty { return jobQueue.removeFirst() }
    guard let first = listedJobs.first else { throw ManagedAnalysisClientError.notFound }
    return first
}
```

Change the existing test helper to accept completed progress and add a literal result-page helper:

```swift
private func job(
    status: ManagedAnalysisJobStatus = .running,
    completedCues: Int = 0
) -> ManagedAnalysisJob {
    ManagedAnalysisJob(
        jobId: "job-1", status: status, tier: .pro,
        createdAt: 1, updatedAt: 2,
        completedCues: completedCues, totalCues: 2,
        tokensIn: 0, tokensOut: 0, errorCode: nil,
        resultEntryId: "entry-1"
    )
}

private func runningPage(firstTranslation: String = "") -> ManagedAnalysisResultsPage {
    let batches = firstTranslation.isEmpty
        ? []
        : [ManagedAnalysisCompletedBatch(
            batchIndex: 0,
            subtitles: [cue(0, translation: firstTranslation)]
        )]
    return ManagedAnalysisResultsPage(
        jobId: "job-1", entryId: "entry-1", status: .running,
        completedCues: batches.isEmpty ? 0 : 1, totalCues: 2,
        nextBatchCursor: batches.isEmpty ? -1 : 0,
        batches: batches, errorCode: nil
    )
}
```

Add these three `@MainActor` tests:

```swift
func testCancelKeepsMergedCuesAndExposesResume() async throws {
    let api = API(
        details: [entry(translations: ["", ""])],
        jobs: [job()],
        results: [runningPage(firstTranslation: "第一句")],
        cancelResponse: job(status: .cancelled, completedCues: 1)
    )
    let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
    await viewModel.load(id: "entry-1", token: "token")
    await viewModel.discoverManagedAnalysis(token: "token")
    let before = viewModel.displayedCues.map(\.translation)
    await viewModel.cancelManagedAnalysis(token: "token")

    XCTAssertEqual(viewModel.managedProgress?.status, .cancelled)
    XCTAssertEqual(viewModel.displayedCues.map(\.translation), before)
    XCTAssertTrue(viewModel.managedProgress?.canResume == true)
    let calls = await api.cancelCalls()
    XCTAssertEqual(calls, ["job-1"])
    XCTAssertNil(viewModel.managedProgressError)
}

func testCancelFailurePreservesRunningStateAndShowsRetryableError() async throws {
    let api = API(
        details: [entry(translations: ["", ""])],
        jobs: [job()],
        results: [runningPage()],
        cancelError: .network("offline")
    )
    let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
    await viewModel.load(id: "entry-1", token: "token")
    await viewModel.discoverManagedAnalysis(token: "token")
    await viewModel.cancelManagedAnalysis(token: "token")

    XCTAssertEqual(viewModel.managedProgress?.status, .running)
    XCTAssertEqual(viewModel.managedProgressError, "暂时无法停止解析，请稍后重试")
    XCTAssertFalse(viewModel.managedCancelling)
}

func testCancelCompletionRaceReloadsFinalEntry() async throws {
    let final = entry(translations: ["最终第一句", "最终第二句"])
    let api = API(
        details: [entry(translations: ["", ""]), final],
        jobs: [job()],
        results: [runningPage()],
        cancelError: .invalidState,
        jobResponses: [job(status: .completed, completedCues: 2)]
    )
    let viewModel = LibraryDetailViewModel(api: api, managedAPI: api)
    await viewModel.load(id: "entry-1", token: "token")
    await viewModel.discoverManagedAnalysis(token: "token")
    await viewModel.cancelManagedAnalysis(token: "token")

    XCTAssertEqual(viewModel.managedProgress?.status, .completed)
    XCTAssertEqual(viewModel.displayedCues.map(\.translation), ["最终第一句", "最终第二句"])
    XCTAssertNil(viewModel.managedProgressError)
}
```

- [ ] **Step 2: Write failing presentation tests**

Add literal behavior checks in `ManagedAnalysisPresentationTests.swift`:

```swift
func testLibraryProgressCancellationCapabilityAndLabels() {
    XCTAssertTrue(ManagedAnalysisProgressState(job: job(.queued)).canCancel)
    XCTAssertTrue(ManagedAnalysisProgressState(job: job(.running)).canCancel)
    XCTAssertFalse(ManagedAnalysisProgressState(job: job(.failed)).canCancel)
    XCTAssertEqual(
        ManagedAnalysisProgressState(job: job(.cancelled, completed: 25)).label,
        "部分解析 · 已停止"
    )
    XCTAssertEqual(
        ManagedAnalysisProgressState(job: job(.cancelled, completed: 0)).label,
        "仅英文 · 已停止"
    )
}
```

- [ ] **Step 3: Run the focused tests to verify RED**

Commit and push the test-only RED state, then use the macOS CI runner because the active workstation is Windows:

```powershell
git add whatsub-mobileTests/LibraryManagedAnalysisTests.swift whatsub-mobileTests/ManagedAnalysisPresentationTests.swift
git commit -m "test: cover stopping managed analysis"
git push origin codex/progressive-mobile-analysis
$redRunId = gh run list --workflow ci.yml --branch codex/progressive-mobile-analysis --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $redRunId --exit-status
```

Expected: compile/test failure because `canCancel`, `managedCancelling`, and `cancelManagedAnalysis(token:)` do not exist and cancelled labels still use the old copy.

- [ ] **Step 4: Implement progress presentation and cancellation**

In `ProgressiveAnalysisOverlay.swift` add:

```swift
var canCancel: Bool { status == .queued || status == .running }

case .cancelled:
    return completedCues > 0 ? "部分解析 · 已停止" : "仅英文 · 已停止"
```

In `LibraryDetailViewModel.swift` add:

```swift
@Published var managedCancelling = false

func cancelManagedAnalysis(token: String) async {
    guard let progress = managedProgress, progress.canCancel, !managedCancelling else { return }
    managedCancelling = true
    managedProgressError = nil
    defer { managedCancelling = false }

    do {
        let job = try await managedAPI.cancel(id: progress.jobID, token: token)
        managedProgress = ManagedAnalysisProgressState(job: job)
        stopManagedProgress()
    } catch ManagedAnalysisClientError.invalidState {
        do {
            let latest = try await managedAPI.job(id: progress.jobID, token: token)
            managedProgress = ManagedAnalysisProgressState(job: latest)
            if latest.status == .completed, let entry {
                stopManagedProgress()
                managedFinalSyncPending = !(await reloadFinalEntry(id: entry.id, token: token))
            } else if latest.status == .queued || latest.status == .running {
                startManagedProgress(token: token)
            } else {
                stopManagedProgress()
            }
        } catch {
            managedProgressError = "暂时无法停止解析，请稍后重试"
        }
    } catch {
        managedProgressError = "暂时无法停止解析，请稍后重试"
    }
}
```

Do not mutate `displayedCues`, `progressiveOverlay`, or `managedBatchCursor` in the successful cancellation branch.

- [ ] **Step 5: Commit Task 1**

```powershell
git add whatsub-mobile/Library/ProgressiveAnalysisOverlay.swift whatsub-mobile/Library/LibraryDetailViewModel.swift
git commit -m "feat: stop managed analysis from library"
```

- [ ] **Step 6: Push Task 1 and verify GREEN on macOS CI**

```powershell
git push origin codex/progressive-mobile-analysis
$greenRunId = gh run list --workflow ci.yml --branch codex/progressive-mobile-analysis --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $greenRunId --exit-status
```

Expected: `LibraryManagedAnalysisTests` and `ManagedAnalysisPresentationTests` pass.

### Task 2: Library Banner Button and Confirmation Dialog

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Test: compile coverage through the app target and the Task 1 presentation/ViewModel tests.

**Interfaces:**
- Consumes: `ManagedAnalysisProgressState.canCancel`, `LibraryDetailViewModel.managedCancelling`, and `cancelManagedAnalysis(token:)` from Task 1.
- Produces: a compact “停止” action, confirmation dialog, and disabled “正在停止…” state in the Library progress banner.

- [ ] **Step 1: Add confirmation state and the compact banner action**

Add view state near the existing confirmation flags:

```swift
@State private var confirmStopAnalysis = false
```

In `managedAnalysisBanner`, render the action before the existing resume branch:

```swift
if progress.canCancel {
    Button(vm.managedCancelling ? "正在停止…" : "停止") {
        confirmStopAnalysis = true
    }
    .font(.caption.weight(.semibold))
    .buttonStyle(.borderless)
    .foregroundStyle(.red)
    .disabled(vm.managedCancelling || vm.managedResuming)
} else if progress.canResume {
    Button(vm.managedResuming ? "正在继续…" : "继续 AI 解析") {
        guard let token = appState.session?.sessionToken else { return }
        Task { await vm.resumeManagedAnalysis(token: token) }
    }
    .font(.caption.weight(.semibold))
    .buttonStyle(.borderless)
    .disabled(vm.managedResuming || vm.managedCancelling)
}
```

Attach one confirmation dialog to the root view:

```swift
.confirmationDialog(
    "停止 AI 解析？",
    isPresented: $confirmStopAnalysis,
    titleVisibility: .visible
) {
    Button("停止解析", role: .destructive) {
        guard let token = appState.session?.sessionToken else { return }
        Task { await vm.cancelManagedAnalysis(token: token) }
    }
    Button("继续解析", role: .cancel) {}
} message: {
    Text("已完成的翻译会保留，未完成部分将停止解析，之后可以继续。")
}
```

- [ ] **Step 2: Commit Task 2**

```powershell
git add whatsub-mobile/Library/LibraryDetailView.swift
git commit -m "ui: confirm stopping library analysis"
```

- [ ] **Step 3: Push and run the complete macOS CI suite**

```powershell
git push origin codex/progressive-mobile-analysis
$uiRunId = gh run list --workflow ci.yml --branch codex/progressive-mobile-analysis --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $uiRunId --exit-status
```

Expected: app target builds and all `whatsub-mobileTests` pass.

### Task 3: CI, Integration, and TestFlight

**Files:**
- Verify only: `.github/workflows/ci.yml`
- Verify only: `.github/workflows/testflight.yml`
- No source version edit: `project.yml` remains `MARKETING_VERSION: "1.0.2"`.

**Interfaces:**
- Consumes: the two implementation commits from Tasks 1–2.
- Produces: a green simulator build/unit-test run and a new TestFlight build whose number is assigned by the workflow.

- [ ] **Step 1: Push the feature branch and verify CI**

```powershell
git push origin codex/progressive-mobile-analysis
$featureRunId = gh run list --workflow ci.yml --branch codex/progressive-mobile-analysis --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $featureRunId --exit-status
```

Expected: `Build for iOS Simulator + Screenshot` completes successfully.

- [ ] **Step 2: Merge the reviewed branch into `main` and push**

```powershell
git -C "C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile" checkout main
git -C "C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile" pull --ff-only origin main
git -C "C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile" merge --no-ff codex/progressive-mobile-analysis
git -C "C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile" push origin main
```

Expected: merge and push succeed without force-push. A push to `main` starts both CI and TestFlight workflows.

- [ ] **Step 3: Watch CI and TestFlight to completion**

```powershell
$ciRunId = gh run list --workflow ci.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId'
$testFlightRunId = gh run list --workflow testflight.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $ciRunId --exit-status
gh run watch $testFlightRunId --exit-status
```

Expected: both workflows complete successfully; TestFlight uploads a new `1.0.2` build with `CURRENT_PROJECT_VERSION = github.run_number + 100`.

- [ ] **Step 4: Report the uploaded build and manual verification path**

Verify on the new TestFlight build:

1. Start phone-side managed analysis and enter its provisional Library video.
2. Wait until at least one translated batch appears.
3. Tap `停止`, confirm `停止解析`, and verify the existing translation remains.
4. Leave and re-enter the video; verify the stopped state is restored.
5. Tap `继续 AI 解析`; verify progress resumes after the already completed cues rather than returning to zero.

Report the exact TestFlight build number and workflow URLs.
