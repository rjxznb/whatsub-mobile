# iOS Pro AI Feature Trials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Quick Chat, video roleplay, Live Scene, and Photo AI ongoing Pro benefits while giving every free account one complete, server-authoritative trial of each feature.

**Architecture:** `whatsub-license` owns the `(email, feature_key)` trial state and exposes session-authenticated entitlement/start/consume APIs. `whatsub-mobile` owns one injected `FeatureAccessStore` that caches entry state, starts trials before feature work, persists pending consumes before showing valuable results, and treats managed relay and BYOK identically. The backend ships first and is backward-compatible; the iOS gate ships second.

**Tech Stack:** Hono, TypeScript, PostgreSQL, Vitest, Swift 5.10, SwiftUI, StoreKit 2, XCTest, XcodeGen, iOS 16+.

## Global Constraints

- Feature keys are exactly `quick_chat`, `video_roleplay`, `live_scene`, and `photo_ai`.
- Existing and new free accounts start with all four trials available; no historical AI usage is backfilled.
- A free trial is consumed only after the feature-specific valid result is persisted locally for retry.
- Failure, timeout, empty output, parse failure, or cancellation before a valid result does not consume a trial.
- Consumption does not interrupt the currently open session; a new session or flow must call `start` again.
- BYOK and managed relay pass through the same feature gate; BYOK secrets never leave the device.
- Library/video/corpus quotas, public-corpus policy, and managed-LLM monthly token accounting do not change.
- Old iOS builds remain functional after the backend deployment.
- Account deletion removes `feature_trials`; demo-review account deletion remains a no-op.

---

### Task 1: Add the backend trial state model and database operations

**Repository:** `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license`

**Files:**
- Create: `src/lib/featureTrials.ts`
- Create: `tests/feature-trials-db.test.ts`
- Modify: `schema.sql`
- Modify: `src/lib/db.ts`
- Modify: `tests/schema.test.ts`
- Modify: `tests/auth-routes.test.ts`

**Interfaces:**
- Produces `FEATURE_KEYS`, `FeatureKey`, `FeatureTrialState`, and `isFeatureKey(value)`.
- Produces `Database.getFeatureTrialStates(email)`, `startFeatureTrial(email, feature, now)`, and `consumeFeatureTrial(email, feature, now)`.
- `startFeatureTrial` returns `in_progress` for a first/repeated unconsumed start and `consumed` for an already consumed row.
- `consumeFeatureTrial` returns `started | consumed | missing`, where repeated consumption is `consumed`.

- [ ] **Step 1: Write failing database and schema tests**

Create tests that assert the four-key whitelist, an initially empty account, idempotent start, independent feature rows, idempotent consume, concurrent start producing one row, and account deletion removing rows. Add a schema assertion for the primary key and feature-key check constraint.

```ts
expect(await db.getFeatureTrialStates('free@x.com')).toEqual({});
expect(await db.startFeatureTrial('free@x.com', 'quick_chat', 100)).toBe('in_progress');
expect(await db.startFeatureTrial('free@x.com', 'quick_chat', 200)).toBe('in_progress');
expect(await db.consumeFeatureTrial('free@x.com', 'quick_chat', 300)).toBe('consumed');
expect(await db.startFeatureTrial('free@x.com', 'quick_chat', 400)).toBe('consumed');
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
pnpm vitest run tests/feature-trials-db.test.ts tests/schema.test.ts tests/auth-routes.test.ts
```

Expected: failures because `feature_trials` and the database methods do not exist.

- [ ] **Step 3: Add the table and whitelist**

Add an idempotent table with a database-level whitelist:

```sql
CREATE TABLE IF NOT EXISTS feature_trials (
  email TEXT NOT NULL,
  feature_key TEXT NOT NULL CHECK (feature_key IN ('quick_chat','video_roleplay','live_scene','photo_ai')),
  started_at BIGINT NOT NULL,
  consumed_at BIGINT,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (email, feature_key)
);
```

Do not seed or backfill rows.

- [ ] **Step 4: Implement atomic database methods**

Use `INSERT ... ON CONFLICT DO UPDATE` without overwriting `started_at` or `consumed_at` for `start`; use `UPDATE ... SET consumed_at = COALESCE(consumed_at, $3)` for `consume`. Return normalized states rather than raw rows.

- [ ] **Step 5: Extend account deletion**

Add `DELETE FROM feature_trials WHERE email = $1` to `deleteUserAccount`, seed a trial in the existing account-deletion test, and assert it is gone afterward.

- [ ] **Step 6: Run tests and commit**

```powershell
pnpm vitest run tests/feature-trials-db.test.ts tests/schema.test.ts tests/auth-routes.test.ts
git add schema.sql src/lib/featureTrials.ts src/lib/db.ts tests/feature-trials-db.test.ts tests/schema.test.ts tests/auth-routes.test.ts
git commit -m "feat: persist per-feature AI trials"
```

---

### Task 2: Expose authenticated feature entitlement APIs

**Repository:** `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-license`

**Files:**
- Create: `src/routes/features.ts`
- Create: `tests/feature-routes.test.ts`
- Modify: `src/index.ts`
- Modify: `nginx/whatsub.conf`

**Interfaces:**
- `GET /api/features/entitlements` returns `{ isPro, features: Record<FeatureKey, 'available'|'in_progress'|'consumed'> }`.
- `POST /api/features/:featureKey/start` returns `{ featureKey, access: 'pro'|'trial', state: 'available'|'in_progress'|'consumed' }` or `403 { error:'feature_subscription_required' }`.
- `POST /api/features/:featureKey/consume` returns `{ ok:true, state:'consumed' }`; a free account without start receives `409 { error:'feature_trial_not_started' }`.
- `POST /api/features/:featureKey/event` accepts only `{ event:'paywall_shown'|'purchase_success' }` and emits a structured, content-free log.

- [ ] **Step 1: Write failing route tests**

Cover no bearer, invalid feature key, all four initial `available` states, start idempotency, consume-before-start conflict, consume idempotency, consumed free-user rejection, active iOS subscription, active web subscription, and event whitelist validation.

```ts
const first = await authed('/api/features/quick_chat/start', { method: 'POST' });
expect(first.status).toBe(200);
expect(await first.json()).toMatchObject({ access: 'trial', state: 'in_progress' });

await authed('/api/features/quick_chat/consume', { method: 'POST' });
expect((await authed('/api/features/quick_chat/start', { method: 'POST' })).status).toBe(403);
```

- [ ] **Step 2: Verify RED**

```powershell
pnpm vitest run tests/feature-routes.test.ts
```

Expected: 404 because the route is not mounted.

- [ ] **Step 3: Implement and mount the route**

Use `requireSession(db)` and derive email only from Hono context. Use `hasActiveSubscription(db,email,Date.now())` for both web and iOS Pro. Reject invalid keys before database access. Log only email hash or normalized feature/event metadata—never AI content.

- [ ] **Step 4: Confirm nginx compatibility**

Document in `nginx/whatsub.conf` that iOS calls `/api/license/features/...`, which the existing trailing-slash proxy rewrites to backend `/api/features/...`; do not add a competing location block.

- [ ] **Step 5: Run backend verification and commit**

```powershell
pnpm vitest run tests/feature-routes.test.ts tests/auth-membership.test.ts tests/auth-routes.test.ts
pnpm test
pnpm typecheck
pnpm build
git add src/routes/features.ts src/index.ts nginx/whatsub.conf tests/feature-routes.test.ts
git commit -m "feat: expose AI feature trial entitlements"
```

---

### Task 3: Build the iOS centralized feature access layer

**Repository:** `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile`

**Files:**
- Create: `whatsub-mobile/FeatureAccess/FeatureAccessModels.swift`
- Create: `whatsub-mobile/FeatureAccess/FeatureAccessPersistence.swift`
- Create: `whatsub-mobile/FeatureAccess/FeatureAccessStore.swift`
- Create: `whatsub-mobileTests/FeatureAccessStoreTests.swift`
- Modify: `whatsub-mobile/Networking/Endpoints.swift`
- Modify: `whatsub-mobile/Networking/DTOs.swift`
- Modify: `whatsub-mobile/Networking/WhatsubAPI.swift`
- Modify: `whatsub-mobile/App/WhatsubMobileApp.swift`

**Interfaces:**
- `FeatureKey: String, Codable, CaseIterable` with the same four wire values.
- `FeatureTrialState: String, Codable` with `available`, `in_progress`, `consumed`.
- `FeatureAccessGrant` is in-memory only and identifies `feature` plus `access: pro|trial`.
- `FeatureAccessStore.refresh(token:email:localPro:)`, `start(feature:token:email:localPro:) async -> FeatureAccessGrant`, `recordSuccessfulResult(feature:grant:token:email:)`, and `retryPendingConsumes(token:email:)`.
- `FeatureEntryPresentation` maps state to `normal`, `freeTrial`, `continueTrial`, `subscriptionRequired`, or `temporarilyUnavailable`.

- [ ] **Step 1: Write failing store tests with an injected API spy and temporary persistence URL**

Test state mapping, local-Pro immediate grant, cached-Pro offline grant, free start requiring server success, 403 mapping only to `subscriptionRequired`, network error mapping to retry messaging, managed/BYOK independence, durable pending consume, successful retry cleanup, and account-key isolation.

```swift
let grant = try await store.start(
    feature: .quickChat,
    token: "session",
    email: "free@x.com",
    localPro: false
)
XCTAssertEqual(grant.access, .trial)

store.recordSuccessfulResult(feature: .quickChat, grant: grant, token: "session", email: "free@x.com")
XCTAssertTrue(persistence.pendingConsumes(email: "free@x.com").contains(.quickChat))
```

- [ ] **Step 2: Verify RED through branch CI or local Xcode**

Run the focused XCTest target and confirm missing FeatureAccess types cause the expected compile failure.

- [ ] **Step 3: Add wire models and API methods**

Use `/api/license/features/entitlements`, `/api/license/features/{key}/start`, `/consume`, and `/event`. Preserve `APIError.server(403,"feature_subscription_required")` so only `FeatureAccessStore` converts that exact error into a subscription decision.

- [ ] **Step 4: Implement persistence**

Persist cached entitlement snapshots and pending consumes keyed by lowercase email in one atomic JSON file under `Documents`. `recordSuccessfulResult` must synchronously save the pending marker before scheduling the consume request. Never persist grants, chat text, images, prompts, or API keys.

- [ ] **Step 5: Implement the store and root injection**

Create one `@StateObject` in `WhatsubMobileApp`, inject it beside `AppState` and `StoreManager`, refresh after authentication without blocking `gateReady`, and retry pending consumes on login/foreground. Offline cached Pro and `StoreManager.hasLocalSub` may grant access; a free account without a successful start may not.

- [ ] **Step 6: Run focused tests and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -sdk iphonesimulator test -only-testing:whatsub-mobileTests/FeatureAccessStoreTests
git add whatsub-mobile/FeatureAccess whatsub-mobile/Networking whatsub-mobile/App/WhatsubMobileApp.swift whatsub-mobileTests/FeatureAccessStoreTests.swift
git commit -m "feat: centralize iOS AI feature access"
```

---

### Task 4: Gate Quick Chat and video roleplay, then consume on the first valid reply

**Repository:** `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile`

**Files:**
- Modify: `whatsub-mobile/Corpus/CorpusView.swift`
- Modify: `whatsub-mobile/Practice/QuickChat/QuickChatView.swift`
- Modify: `whatsub-mobile/Practice/QuickChat/QuickChatViewModel.swift`
- Modify: `whatsub-mobile/Practice/Roleplay/RoleplayTabView.swift`
- Modify: `whatsub-mobile/Practice/Roleplay/RoleplaySessionView.swift`
- Modify: `whatsub-mobile/Practice/Roleplay/RoleplayTabViewModel.swift`
- Create: `whatsub-mobileTests/QuickChatViewModelTests.swift`
- Create: `whatsub-mobileTests/FeatureSessionGateTests.swift`

**Interfaces:**
- `QuickChatView` receives `featureGrant: FeatureAccessGrant` and `onFirstValidReply: (FeatureAccessGrant) -> Void`.
- `QuickChatViewModel` receives `onFirstValidAssistantReply: () -> Void` and calls it once per VM lifetime before typewriter display of the first non-empty sanitized assistant reply.
- Corpus holds the quick-chat grant only for the presented full-screen session and clears it on dismiss.
- Roleplay starts access before scenario work, passes a `videoRoleplay` grant into the session, clears it on session dismiss, and rechecks before a second session.

- [ ] **Step 1: Write failing lifecycle tests**

Test that opening/first reply calls the callback once, empty/error replies call it zero times, later turns do not call it again, Quick Chat uses `.quickChat`, and roleplay uses `.videoRoleplay`.

- [ ] **Step 2: Verify RED**

Run focused QuickChat and feature-session tests; expect initializer/callback failures.

- [ ] **Step 3: Gate Quick Chat before opening the launcher**

At `tapQuickChat`, call `FeatureAccessStore.start(.quickChat,...)`. Show “免费体验 1 次” or “继续免费体验” near the entry based on store presentation. On the exact subscription-required result show `SubscribeSheet`; on network failure show retry text, not the subscription sheet.

- [ ] **Step 4: Gate roleplay before generating/entering the feature**

When the roleplay tab becomes active, obtain a grant before `loadIfNeeded()`. Scene-card generation alone never calls consume. Selecting a scenario requires a current grant. When a session closes, clear the grant so selecting another scenario performs a fresh `start`.

- [ ] **Step 5: Consume before the first reply becomes visible**

In `QuickChatViewModel.runOneTurn`, after obtaining a non-empty sanitized `dialog` and before setting the first visible `assistantText`, invoke the one-shot callback. The callback synchronously records the pending consume and starts background sync through `FeatureAccessStore`.

- [ ] **Step 6: Verify and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -sdk iphonesimulator test -only-testing:whatsub-mobileTests/QuickChatViewModelTests -only-testing:whatsub-mobileTests/FeatureSessionGateTests
git add whatsub-mobile/Corpus whatsub-mobile/Practice/QuickChat whatsub-mobile/Practice/Roleplay whatsub-mobileTests
git commit -m "feat: gate iOS conversation features behind trials"
```

---

### Task 5: Gate Live Scene and Photo AI, then consume at their successful result boundaries

**Repository:** `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile`

**Files:**
- Modify: `whatsub-mobile/Camera/CameraTabView.swift`
- Modify: `whatsub-mobile/Practice/LiveScene/LiveSceneView.swift`
- Modify: `whatsub-mobile/Practice/LiveScene/LiveSceneViewModel.swift`
- Modify: `whatsub-mobile/Photo/PhotoReviewView.swift`
- Modify: `whatsub-mobile/Photo/PhotoReviewViewModel.swift`
- Create: `whatsub-mobileTests/LiveSceneViewModelTests.swift`
- Create: `whatsub-mobileTests/PhotoReviewViewModelTests.swift`

**Interfaces:**
- `LiveSceneViewModel` receives `onSuccessfulGrade: () -> Void` and invokes it immediately before assigning `.review`.
- `PhotoReviewViewModel` receives `onSuccessfulAnalysis: () -> Void` and invokes it immediately before publishing `analysis`/`.reviewing`.
- Each view holds one grant for one flow, clears it when “再来一次/重拍” starts a new flow, and asks the store again.

- [ ] **Step 1: Write failing success-boundary tests**

Assert Live Scene does not consume on classification, prompt generation, empty speech, or grading failure, but does once before review on a successful grade. Assert Photo AI does not consume on OCR success or analyzer failure, but does once before successful analysis becomes visible.

- [ ] **Step 2: Verify RED**

Run focused Live Scene and Photo ViewModel tests; expect missing callback initializers/call counts.

- [ ] **Step 3: Gate Live Scene at the first AI flow action**

Display entry state in `CameraTabView`. Before accepting the first selected/captured image for a free account, call `start(.liveScene)`. Preserve the grant through prompt/recording/grading. On successful review, record consume. “再来一次” clears the grant and requires another start; the already displayed review remains visible after consumption.

- [ ] **Step 4: Gate Photo AI before analysis**

Allow camera/gallery and on-device OCR without consuming. Before the “AI 提取重点短语” analyzer call, obtain `start(.photoAI)`. On successful analysis, persist/consume before review. Resetting to another image clears the grant and requires a new start.

- [ ] **Step 5: Keep failure classes distinct**

`feature_subscription_required` opens `SubscribeSheet`; entitlement network failure shows “暂时无法确认免费体验，请检查网络后重试”; managed token quota failures continue through existing `RemoteFailure` handling.

- [ ] **Step 6: Verify and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -sdk iphonesimulator test -only-testing:whatsub-mobileTests/LiveSceneViewModelTests -only-testing:whatsub-mobileTests/PhotoReviewViewModelTests
git add whatsub-mobile/Camera whatsub-mobile/Practice/LiveScene whatsub-mobile/Photo whatsub-mobileTests
git commit -m "feat: gate iOS camera AI features behind trials"
```

---

### Task 6: Update entry badges, subscription value copy, and purchase refresh

**Repository:** `C:/Users/Jimmy Spector/Desktop/whatsub/whatsub-mobile`

**Files:**
- Create: `whatsub-mobile/FeatureAccess/FeatureTrialBadge.swift`
- Modify: `whatsub-mobile/Store/SubscribeSheet.swift`
- Modify: `whatsub-mobile/Store/StoreManager.swift`
- Modify: `whatsub-mobile/App/WhatsubMobileApp.swift`
- Modify: the four entry views from Tasks 4–5
- Create: `whatsub-mobileTests/FeatureEntryPresentationTests.swift`

**Interfaces:**
- `FeatureTrialBadge` renders no badge for Pro, “免费体验 1 次” for available, and “继续免费体验” for in-progress.
- Purchase callbacks set local Pro immediately, refresh `/me` and feature entitlements, retry pending consumes, and emit `purchase_success` for the feature that opened the paywall.

- [ ] **Step 1: Write failing presentation tests**

Test every state-to-copy mapping and assert unknown/network-error state is not rendered as consumed or Pro.

- [ ] **Step 2: Reorder SubscribeSheet benefits**

Use this order without hard-coded prices:

```text
• AI 对话陪练持续使用
• 视频角色扮演持续使用
• 实景口语与拍照 AI 持续使用
• whatSub 托管 AI 月度配额
• 50 个云端视频，单视频 500MB / 60 分钟
• 1000 条个人语料和公共语料库
```

- [ ] **Step 3: Wire immediate purchase unlock**

Keep existing StoreKit JWS reporting. After StoreKit locally verifies a subscription, all four gates must treat `hasLocalSub` as Pro immediately. Then refresh `/me`, refresh feature entitlements, and preserve the existing explicit “已扣款但登记失败” error instead of presenting another purchase action.

- [ ] **Step 4: Add content-free funnel events**

Emit `paywall_shown` only when a consumed free feature opens its subscription sheet, and `purchase_success` after local StoreKit success for that origin feature. Failures are best-effort and must never block UI.

- [ ] **Step 5: Verify and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile -sdk iphonesimulator test -only-testing:whatsub-mobileTests/FeatureEntryPresentationTests
git add whatsub-mobile/FeatureAccess whatsub-mobile/Store whatsub-mobile/App/WhatsubMobileApp.swift whatsub-mobile/Corpus whatsub-mobile/Practice whatsub-mobile/Camera whatsub-mobile/Photo whatsub-mobileTests
git commit -m "ui: present Pro AI trials and benefits"
```

---

### Task 7: Run cross-repository verification and prepare safe rollout

**Repositories:** `whatsub-license`, `whatsub-mobile`

**Files:**
- Modify: `whatsub-license/AGENTS.md`
- Modify: `whatsub-mobile/CLAUDE.md`

**Interfaces:**
- No new runtime interfaces; this task proves and documents the complete contract.

- [ ] **Step 1: Run full backend verification**

```powershell
pnpm test
pnpm typecheck
pnpm build
git diff --check
```

Expected: all feature trial, auth deletion, subscription, relay, corpus, and library tests pass.

- [ ] **Step 2: Run real PostgreSQL schema smoke**

Apply `schema.sql` twice with `psql -v ON_ERROR_STOP=1` against disposable PostgreSQL, verify the feature whitelist and primary key, run concurrent start/consume SQL, and roll back/drop the disposable database. This is required because pg-mem does not enforce every PostgreSQL constraint.

- [ ] **Step 3: Run full iOS CI**

Push the feature branch and require the existing macOS workflow to pass simulator build, all XCTest, app launch, and screenshot artifact creation.

- [ ] **Step 4: Manually exercise the four lifecycle matrices**

For each feature test: available → in-progress; failure before result → still in-progress; valid result → consumed; current page continues; close/re-enter → SubscribeSheet; purchase → immediate unlock. Repeat one BYOK path and one managed-relay path. Sign in on a second device/account session to verify consumed state sync.

- [ ] **Step 5: Document behavior and deployment order**

Record the new table/API, no-backfill migration, consume points, account deletion, pending-consume file, and backward compatibility. Deploy in this order only:

1. apply backend schema and deploy backend;
2. smoke-test `/api/license/features/entitlements` with a test session;
3. ship iOS/TestFlight;
4. observe start/consume/paywall/purchase logs;
5. never roll back the backend while the gated iOS build is live.

- [ ] **Step 6: Commit documentation**

In `whatsub-license`:

```powershell
git add AGENTS.md
git commit -m "docs: document AI feature trial backend"
```

In `whatsub-mobile`:

```powershell
git add CLAUDE.md
git commit -m "docs: document iOS AI feature trials"
```
