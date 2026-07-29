# Desktop Library replacement — final-fix report

Date: 2026-07-29  
Branch in all three repositories: `codex/desktop-library-replace`  
Disposition: fixes committed locally; not pushed, merged, deployed, or connected to production.

## Implementation commits

- Backend (`whatsub-license`): `34abf86` — `fix: isolate library replacements by attempt`
- Desktop (`whatsub`): `9c1185a` — `fix: bind replacements to claim attempts`
- Mobile (`whatsub-mobile`): `cec2dc0` — `fix: clarify desktop replacement state`

The report itself is committed separately after the implementation commits so it can record their stable hashes.

## Findings resolved

### 1. YouTube Music URL parity

- Added `music.youtube.com` to backend YouTube canonicalization.
- Added canonicalization coverage.
- Added enqueue coverage using a Library row whose stored source is a YouTube Music URL.
- Added completion coverage using that stored Music URL, proving the locked target identity check accepts it.

### 2. Accurate iOS replacement copy

Both the confirmation dialog and Library detail card now state that desktop processing regenerates and replaces the video file, subtitles, and analysis. They separately state that the Library entry identity and attached collections remain associated.

### 3. Per-claim replacement attempt isolation

- Added nullable `import_queue.attempt_token` with a rerunnable additive migration.
- Atomic replacement claim now mints and returns a UUID attempt token. Ordinary import claims return a null token and keep their existing behavior.
- Replacement upload/staging-key issuance, atomic completion, and failure transition require the exact claimed attempt token.
- Retry clears the prior attempt token and staging-key references; the next claim receives a fresh token and fresh immutable staging generation.
- Generic status mutation is prohibited for replacement jobs; their terminal writes must use the dedicated token-bound paths.
- Desktop claim/result types and the Tauri/TypeScript pipeline now propagate the token through video/audio staging, completion, and failure reporting.
- Deterministic interleaving regression covers: claim old attempt → fail → retry → claim new attempt → old staging rejected → old completion rejected → old late failure rejected → new attempt remains processing.

### 4. Deterministic retry conflict

Retrying an old failed replacement now runs transactionally and checks for another active replacement for the same owner/target. It returns the existing active job as a deterministic `409 active_replacement`. A PostgreSQL `23505` race fallback resolves the same active row instead of surfacing a 500.

### 5. Replacement jobs and Library quota

DB quota tests now prove that both pending and processing replacement jobs are excluded from `pendingImportCount`; ordinary pending imports remain counted.

### 6. iOS deduplicated enqueue status

The enqueue response now exposes the actual queue status. iOS uses a returned `processing` status immediately instead of always showing pending or starting a refresh/poll loop. The response field is optional on iOS for compatibility with an older backend response.

### 7. iOS duration precheck

The existing local gate was verified and strengthened with call-count tests:

- authoritative input: `appState.currentUser?.libraryLimits?.maxVideoSeconds` from the account response;
- known duration strictly greater than the known limit: block locally and make zero enqueue requests;
- duration equal to the limit: allow one enqueue request;
- unknown duration or temporarily unknown limit: allow one enqueue request;
- backend duration validation remains authoritative.

## Changed files

### Backend — `whatsub-license`

- `schema.sql`
- `src/lib/canonicalizeUrl.ts`
- `src/lib/db.ts`
- `src/routes/library.ts`
- `tests/canonicalizeUrl.test.ts`
- `tests/import-queue-db.test.ts`
- `tests/library-quota-db.test.ts`
- `tests/library-routes.test.ts`

### Desktop — `whatsub`

- `client/src/lib/api/importQueue.ts`
- `client/src/lib/api/librarySync.ts`
- `client/src/store/importQueue.ts`
- `client/src/store/importQueue.test.ts`
- `client/src-tauri/src/commands/import_queue_http.rs`
- `client/src-tauri/src/commands/library_replacement.rs`

### Mobile — `whatsub-mobile`

- `whatsub-mobile/Library/LibraryDetailView.swift`
- `whatsub-mobile/Library/LibraryDetailViewModel.swift`
- `whatsub-mobile/Networking/DTOs.swift`
- `whatsub-mobile/Networking/WhatsubAPI.swift`
- `whatsub-mobileTests/LibraryDesktopReplacementTests.swift`

## Test-first evidence

Before implementation, the focused backend suite failed in the newly added Music URL, attempt-token/schema, stale-attempt, response-status, and retry-conflict cases (10 expected failures). The desktop processor suite failed all 7 updated token-propagation expectations. These failures established that the old implementation had no claim-generation identity and did not propagate one from desktop.

After implementation:

### Backend

- `npm test -- tests/canonicalizeUrl.test.ts tests/import-queue-db.test.ts tests/library-quota-db.test.ts tests/library-routes.test.ts`
  - PASS: 4 files, 150 tests.
- `npm test -- --reporter=dot`
  - PASS: 45 files, 659 tests.
- `npm run typecheck`
  - PASS.
- `npm run build`
  - PASS.
- `git diff --check`
  - PASS.

### Desktop

- `npm test -- src/store/importQueue.test.ts`
  - PASS: 1 file, 7 tests.
- `npm test -- --reporter=dot`
  - PASS: 143 files, 978 tests. Existing test stderr diagnostics remained non-fatal.
- `npm run typecheck`
  - PASS.
- `npm run build`
  - PASS with existing Vite chunk-size/dynamic-import warnings.
- `cargo check`
  - PASS with existing unrelated warnings.
- `cargo test`
  - PASS: 174 passed, 1 ignored.
- `rustfmt --check --edition 2021 src/commands/import_queue_http.rs src/commands/library_replacement.rs`
  - PASS. Repository-wide `cargo fmt --check` is already non-clean in many unrelated pre-existing files, so only changed Rust files were used as the scoped formatting gate.
- `git diff --check`
  - PASS.

### Mobile

- Static API/diff review: PASS.
- Added XCTest coverage for response status and the four duration-boundary/request-count cases.
- `git diff --check`: PASS.
- XCTest/Xcode build could not be run locally because this worker is on Windows and neither `swift` nor `xcodebuild` is installed. No push was allowed, so GitHub macOS CI was intentionally not triggered.

## PostgreSQL smoke-test attempt

A disposable local `postgres:16-alpine` container was attempted twice to run `schema.sql` against a legacy queue table and exercise the partial unique index. Both attempts stopped before container creation because Docker Hub token retrieval failed with `Post https://auth.docker.io/token: EOF`; no PostgreSQL image was already cached locally. This was an environment/network limitation, not a schema execution failure. The rerunnable schema and conflict semantics are covered by pg-mem DB/route regressions, including the partial unique-index conflict and the `23505` fallback path.

## Residual risk / rollout note

- A macOS Xcode build and the new mobile XCTest cases remain the only unexecuted code validation.
- A real-PostgreSQL migration smoke test remains desirable once an image or database is available.
- Replacement processing now requires a backend and desktop version that both understand `attemptToken`; ordinary non-replacement import jobs remain backward compatible. Coordinate those two feature components when the branch is eventually released.
- No production migration, deployment, merge, or push was performed.
