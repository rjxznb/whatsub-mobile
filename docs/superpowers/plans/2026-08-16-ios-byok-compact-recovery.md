# iOS BYOK Compact Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace iOS BYOK's legacy full-cue model contract with compact-v1 and make unfinished 50-cue batches recover cue by cue across malformed output, transport retries, pauses, and app restarts.

**Architecture:** `AnalysisEngine` remains the owner of BYOK analysis. Add a strict compact cue validator that rebuilds `Cue` from immutable source data, a batch-scoped highlight budget, and an analysis-only retry classifier. Upgrade `AnalysisCheckpoint` to persist one validated unfinished batch; the engine seeds its resolved map from that checkpoint and sends only missing indexes. Managed background analysis and its SSE reducer are untouched.

**Tech Stack:** Swift 5, Swift Concurrency, Foundation `URLSession`, XCTest, existing `JsonLineParser` and `AnalysisCheckpointStore`.

## Global Constraints

- Normal and durable batch size remains 50 cues.
- BYOK continues to call the user's provider directly; do not route API keys or subtitles through whatSub servers.
- Compact cue output is `{i:number,zh:string,p:[[string,string,string]] | []}`.
- Source index, text, time, and endTime come only from submitted local cues.
- At most one phrase per highlighted cue; phrase length 1–4 English words.
- Usage note length is 25–90 Unicode code points.
- Highlight capacity is `min(10, ceil(originalBatchCueCount / 5))`, shared across every request and repair for that batch.
- A malformed annotation cannot invalidate a non-empty translation.
- Use 4 total requests per unfinished cue batch with 500/1500/3500 ms backoffs; honor a longer `Retry-After`.
- Retry network/transport, HTTP 408/ordinary 429/5xx, empty/truncated streams, and repairable model output.
- Do not retry cancellation, pause, missing config, consent, authentication, quota/balance/policy errors, unsupported/missing model, or deterministic HTTP 4xx.
- Summary failure is fail-open and never removes completed cue batches.
- Do not modify managed-analysis HTTP/SSE protocol, queue state, or server code.

---

### Task 1: Add compact-v1 prompt and deterministic cue validation

**Files:**
- Create: `whatsub-mobile/LLM/CompactAnalysisCue.swift`
- Modify: `whatsub-mobile/LLM/AnalysisPrompts.swift`
- Create: `whatsub-mobileTests/CompactAnalysisCueTests.swift`

**Interfaces:**
- Produces: `CompactAnalysisCue.validate(_:requested:)`, `CompactHighlightBudget.apply(to:)`, `AnalysisPrompts.compactCueMessages` and `AnalysisPrompts.compactRepairMessages`.
- Consumes later: `AnalysisEngine` uses these interfaces for every BYOK cue request.

- [ ] **Step 1: Write failing validator tests**

Cover:

```swift
let source = Cue(index: 7, time: 12.3, endTime: 14.2, text: "I need to catch up")
let output: [String: Any] = [
    "i": 7,
    "zh": "我得赶上进度",
    "p": [["catch up", "赶上进度", "表示补回落下的进度，常用于工作、学习或消息积压后追赶进度的自然语境。"]],
]
let budget = CompactHighlightBudget(limit: 10, used: 0)
let result = try CompactAnalysisCue.validate(output, requested: [7: source])
let accepted = budget.apply(to: result)
XCTAssertEqual(accepted.cue.text, source.text)
XCTAssertEqual(accepted.cue.time, source.time)
XCTAssertEqual(accepted.cue.highlightWords, ["catch up"])
```

Add tests rejecting an unknown index and missing/blank `zh`; accepting a valid
translation with empty annotations when `p` is malformed; rejecting phrases
over four words, non-substrings, and notes outside 25–90 code points; accepting
at most one phrase; and limiting 50 cues to 10 highlights and 13 cues to 3.

- [ ] **Step 2: Run the focused XCTest and verify failure**

On macOS:

```bash
xcodegen generate
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/CompactAnalysisCueTests
```

Expected: FAIL because the compact validator and budget do not exist.

- [ ] **Step 3: Implement the compact data boundary**

Define:

```swift
struct CompactCueValidation {
    let cue: Cue
    let needsAnnotationRepair: Bool
}

final class CompactHighlightBudget {
    let limit: Int
    private(set) var used: Int
    init(limit: Int, used: Int = 0)
    var remaining: Int { max(0, limit - used) }
    func apply(to result: CompactCueValidation) -> CompactCueValidation
}

enum CompactAnalysisCue {
    static func capacity(for cueCount: Int) -> Int
    static func validate(
        _ object: Any,
        requested: [Int: Cue]
    ) throws -> CompactCueValidation
}
```

Build the result from `Cue(index:time:endTime:text:translation:)`, then set its
mutable highlight fields. Never decode model-supplied timestamps or source
text. Count phrase words using a Unicode-aware regular expression equivalent to
desktop `TOKEN_RE`; count usage with `usage.count` after trimming. Keep budget
mutation outside untrusted parsing so malformed, duplicate, or unknown rows
cannot consume a slot before the engine confirms the row is the first accepted
result for an unresolved source offset.

- [ ] **Step 4: Replace the legacy cue prompt with compact-v1 builders**

Add:

```swift
static func compactCueMessages(_ cues: [Cue], maxHighlightedCues: Int) -> [ChatMessage]
static func compactRepairMessages(_ cues: [Cue], maxHighlightedCues: Int) -> [ChatMessage]
```

The system prompt must include the exact shape, 1–4-word rule, 25–90-character
usage rule, high-value/low-value categories, and the exact remaining highlight
allowance. The user message serializes only `index<TAB>JSON-encoded text`.
Tighten the existing summary phrase wording to 1–4 words and 25–90 Chinese code
points without changing the summary JSON envelope expected by
`VideoLearningParser`.

- [ ] **Step 5: Run prompt and validator tests**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/CompactAnalysisCueTests \
  -only-testing:whatsub-mobileTests/AnalysisEngineTests
```

- [ ] **Step 6: Commit**

```bash
git add whatsub-mobile/LLM/CompactAnalysisCue.swift whatsub-mobile/LLM/AnalysisPrompts.swift whatsub-mobileTests/CompactAnalysisCueTests.swift
git commit -m "feat(llm): add compact iOS cue contract"
```

---

### Task 2: Add an analysis-only retry classifier with Retry-After support

**Files:**
- Create: `whatsub-mobile/LLM/AnalysisRetryPolicy.swift`
- Modify: `whatsub-mobile/LLM/ChatCompletionsClient.swift`
- Create: `whatsub-mobileTests/AnalysisRetryPolicyTests.swift`
- Create: `whatsub-mobileTests/ChatCompletionsClientTests.swift`

**Interfaces:**
- Produces: `AnalysisRetryPolicy.decision(for:failedAttempt:)` and provider errors carrying optional `retryAfterMilliseconds`.
- Consumes later: Task 3 uses the decision before replaying an unfinished cue request.

- [ ] **Step 1: Add failing classifier tests**

Assert retry for URL/network errors, status 408, ordinary 429, status 500/503,
empty SSE/protocol content, and an incomplete batch. Assert no retry for
`notConfigured`, `consentRequired`, policy/quota cases, 400/401/403/404, pause,
and cancellation. Assert a 7-second `Retry-After` overrides the local 500 ms
delay.

- [ ] **Step 2: Run and verify failure**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/AnalysisRetryPolicyTests
```

- [ ] **Step 3: Preserve Retry-After in provider errors**

Change only `ChatCompletionsClient.LlmError.api` to carry:

```swift
case api(Int, String, retryAfterMilliseconds: Int?)
```

At both non-streaming and streaming HTTP error boundaries, parse
`Retry-After` as either integer seconds or an HTTP date and attach the delay.
Update existing pattern matches and tests. Calls for local protocol errors use
`nil`.

- [ ] **Step 4: Implement the analysis policy**

Define four total attempts and delays `[500, 1500, 3500]`. The classifier must
be used only by `AnalysisEngine`; do not add retries inside generic `chat`,
`stream`, or `streamChat`, because those methods serve interactive features
whose output or side effects must not be replayed.

- [ ] **Step 5: Run provider and policy tests**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/AnalysisRetryPolicyTests \
  -only-testing:whatsub-mobileTests/ChatCompletionsClientTests
```

- [ ] **Step 6: Commit**

```bash
git add whatsub-mobile/LLM/AnalysisRetryPolicy.swift whatsub-mobile/LLM/ChatCompletionsClient.swift whatsub-mobileTests/AnalysisRetryPolicyTests.swift whatsub-mobileTests/ChatCompletionsClientTests.swift
git commit -m "feat(llm): classify iOS analysis retries"
```

---

### Task 3: Continue an unfinished batch from validated cue indexes

**Files:**
- Modify: `whatsub-mobile/LLM/AnalysisEngine.swift`
- Modify: `whatsub-mobile/LLM/JsonLineParser.swift`
- Modify: `whatsub-mobileTests/AnalysisEngineTests.swift`
- Modify: `whatsub-mobileTests/AnalysisDecodeTests.swift`

**Interfaces:**
- Consumes: compact prompt, validator, highlight budget, and retry policy from Tasks 1–2.
- Produces: `onCueAccepted(batchIndex:cueOffset:cue:needsAnnotationRepair:)` and missing-index continuation inside one engine run.

- [ ] **Step 1: Add the 42-of-50 regression test**

Script the first stream to emit valid compact rows for 42 cues and end. Script
the second stream for the remaining eight. Assert:

- first 42 invoke `onCueAccepted` exactly once;
- the second prompt contains only the remaining eight source indexes;
- progress never decreases;
- the complete batch callback fires exactly once with 50 cues in source order.

Add cases for a malformed row beside valid rows, a transport failure after
valid rows, four no-progress responses, cancellation during backoff, and a
permanent 401 with exactly one request.

- [ ] **Step 2: Run and verify failure**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/AnalysisEngineTests
```

- [ ] **Step 3: Extend the resume interface**

Add to `AnalysisResumeContext`:

```swift
let partialBatch: AnalysisPartialBatch?
let onCueAccepted: (
    _ batchIndex: Int,
    _ cueOffset: Int,
    _ cue: Cue,
    _ needsAnnotationRepair: Bool
) throws -> Void
```

For each unfinished batch, seed `resolvedByOffset` from `partialBatch`, create
one budget for the original batch, and request only unresolved source cues.
Feed JSONL objects through `CompactAnalysisCue.validate`. Before publishing a
cue as recoverable, call `onCueAccepted` synchronously; only then add it to the
resolved map and advance progress.

- [ ] **Step 4: Implement bounded continuation**

After each stream finishes or throws a retryable error:

1. calculate unresolved offsets;
2. return the complete batch if none remain;
3. fail immediately if the error is non-retryable;
4. stop after the fourth request;
5. notify diagnostics with attempt and unresolved count, sleep using the
   abortable policy delay, then request only unresolved cues.

Add an `AnalysisContentError.incompleteBatch([Int])` type instead of encoding
missing indexes in a display string. Keep summary fail-open behavior unchanged.

After every translation is resolved, collect entries whose compact validator
reported `needsAnnotationRepair`. Send `compactRepairMessages` only for those
entries and use the same remaining highlight budget. A repaired cue is written
through `onCueAccepted(..., false)` before replacing its in-memory value.
Transient repair transport errors use the same four-attempt policy, but an
exhausted or malformed repair fails open: persist the translation-only cue with
`needsAnnotationRepair=false` and complete the batch. Annotation repair must
never cause already translated cues to be regenerated.

- [ ] **Step 5: Run engine tests**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/AnalysisEngineTests \
  -only-testing:whatsub-mobileTests/AnalysisDecodeTests
```

- [ ] **Step 6: Commit**

```bash
git add whatsub-mobile/LLM/AnalysisEngine.swift whatsub-mobile/LLM/JsonLineParser.swift whatsub-mobileTests/AnalysisEngineTests.swift whatsub-mobileTests/AnalysisDecodeTests.swift
git commit -m "feat(llm): continue missing iOS BYOK cues"
```

---

### Task 4: Persist and validate an unfinished iOS BYOK batch

**Files:**
- Modify: `whatsub-mobile/Import/AnalysisCheckpointStore.swift`
- Modify: `whatsub-mobileTests/AnalysisCheckpointStoreTests.swift`

**Interfaces:**
- Produces: checkpoint schema v2, `AnalysisPartialBatch`, `recordCue`, and `commitPartialBatch`.
- Consumes later: `ImportViewModel` wires the engine callbacks to these methods.

- [ ] **Step 1: Add failing checkpoint tests**

Cover v1 migration; recording 42 cues one at a time; save/reload; strict source
index/text/time validation; duplicate idempotency; conflicting payload failure;
rejecting a partial batch from another batch index; converting a full partial
batch into one completed batch atomically in the in-memory checkpoint; and
clearing partial state only after the completed checkpoint is written.

- [ ] **Step 2: Run and verify failure**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/AnalysisCheckpointStoreTests
```

- [ ] **Step 3: Define schema v2**

Add:

```swift
struct AnalysisPartialBatch: Codable {
    struct Entry: Codable {
        let cueOffset: Int
        let cue: Cue
        let needsAnnotationRepair: Bool
    }
    let batchIndex: Int
    var entries: [Entry]
}
```

Set `AnalysisCheckpoint.schemaVersion = 2`. Decode version 1 into a migrated
version-2 value by preserving its completed batches and summary and assigning
`partialBatch=nil`; do not leave the decoded `version` equal to 1 because
`validated(sourceCues:)` must accept the migrated value. `recordCue`
must verify the cue against the immutable source cue before replacing an
identical entry or rejecting a conflict. It may replace an entry only for a
monotonic annotation transition with identical source identity and translation:
`needsAnnotationRepair=true` to `false`. Only one partial batch may exist.

- [ ] **Step 4: Preserve crash safety**

Continue using the store's existing atomic file write. The call sequence is:

1. mutate checkpoint with the accepted cue;
2. synchronously save checkpoint;
3. expose the cue as recoverable;
4. after all entries exist, record the completed batch and clear partial state
   in one checkpoint value;
5. atomically save that value.

Never clear the partial batch before the completed batch is present in the same
encoded checkpoint.

- [ ] **Step 5: Run checkpoint tests**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/AnalysisCheckpointStoreTests
```

- [ ] **Step 6: Commit**

```bash
git add whatsub-mobile/Import/AnalysisCheckpointStore.swift whatsub-mobileTests/AnalysisCheckpointStoreTests.swift
git commit -m "feat(import): persist partial BYOK cue batches"
```

---

### Task 5: Wire partial recovery into ImportViewModel

**Files:**
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Modify: `whatsub-mobileTests/ImportBYOKResumeTests.swift`
- Modify: `whatsub-mobileTests/AnalysisStreamDiagnosticsTests.swift`

**Interfaces:**
- Consumes: Task 3's extended `AnalysisResumeContext` and Task 4's checkpoint methods.
- Produces: app restart/pause/retry behavior that resumes the unfinished batch without refetching captions or accepted cues.

- [ ] **Step 1: Add failing integration tests**

Test that 42 accepted cues are saved, the analysis task fails, a new
`ImportViewModel` loads the same checkpoint, and its first provider request
contains only eight cues. Test foreground pause after partial progress and
resume. Test explicit cancellation invalidates the checkpoint lease so a late
stream callback cannot recreate a cancelled checkpoint.

- [ ] **Step 2: Run and verify failure**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/ImportBYOKResumeTests
```

- [ ] **Step 3: Wire the callbacks**

When creating `AnalysisResumeContext`, pass the validated partial batch and an
`onCueAccepted` closure that mutates and saves the checkpoint inside
`BYOKCheckpointLease.withValid`. The complete-batch closure must use
`commitPartialBatch` when committing the active partial batch; completed batches
restored from schema v1 continue to skip requests.

The 90-second no-progress watchdog must use persisted+current parsed cue count.
Any newly accepted cue resets the notion of zero progress. Retry backoff itself
must not trigger the watchdog.

- [ ] **Step 4: Run resume and diagnostics tests**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/ImportBYOKResumeTests \
  -only-testing:whatsub-mobileTests/AnalysisStreamDiagnosticsTests
```

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Import/ImportViewModel.swift whatsub-mobileTests/ImportBYOKResumeTests.swift whatsub-mobileTests/AnalysisStreamDiagnosticsTests.swift
git commit -m "fix(import): resume partial iOS BYOK batches"
```

---

### Task 6: iOS compatibility and final verification

**Files:**
- Verify only; update tests only when a real missing assertion is identified.

- [ ] **Step 1: Run all analysis/import tests**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:whatsub-mobileTests/CompactAnalysisCueTests \
  -only-testing:whatsub-mobileTests/AnalysisRetryPolicyTests \
  -only-testing:whatsub-mobileTests/AnalysisEngineTests \
  -only-testing:whatsub-mobileTests/AnalysisCheckpointStoreTests \
  -only-testing:whatsub-mobileTests/ImportBYOKResumeTests
```

- [ ] **Step 2: Run the complete iOS suite**

```bash
xcodebuild test -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

- [ ] **Step 3: Build Release configuration**

```bash
xcodebuild build -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -configuration Release -destination 'generic/platform=iOS Simulator'
```

- [ ] **Step 4: Manual acceptance test with one BYOK provider**

Use a transcript of at least 60 cues. Verify first subtitles appear
progressively, pause/resume never lowers the translated count, force-quit and
reopen continues the unfinished batch, no more than ten of the first fifty are
highlighted, and disabling the network produces bounded retry rather than a
caption refetch. Invalid API key must fail immediately.

- [ ] **Step 5: Inspect scope**

```bash
git diff --check
git status --short
git log -8 --oneline
```

Expected: only planned LLM/import/tests/project files and this plan changed;
pre-existing untracked `AGENTS.md` and `docs/handoffs/` remain untouched.
