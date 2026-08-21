# iOS LLM Entitlements and StoreKit Top-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide and block BYOK for free/Pro-only iOS accounts, unlock it by purchase-email license ownership, and let Pro users buy consumable Token packs that resume quota-paused analysis.

**Architecture:** `MeResponse.llmEntitlements` drives a pure mode policy used by settings and every LLM call. A StoreKit top-up store loads three consumables, waits for backend credit before finishing, and publishes wallet changes to managed-analysis recovery.

**Tech Stack:** Swift 5.10, SwiftUI, StoreKit 2, URLSession, Keychain, XCTest, iOS 16+

**Spec:** `whatsub-mobile/docs/superpowers/specs/2026-08-21-llm-entitlements-and-token-topups-design.md`

## Global Constraints

- Free: managed experience only; buyout: BYOK only; Pro: managed only; buyout + Pro: both.
- Existing Keychain API configuration remains stored but cannot be read by a disallowed call.
- Consumables: `whatsub_token_1m`, `whatsub_token_5m`, `whatsub_token_15m`.
- Finish a consumable only after backend verification/credit succeeds.
- iOS never links to website permanent-license or Alipay checkout.
- Top-up balance freezes without active Pro and resumes after resubscription.

---

### Task 1: Decode and isolate entitlement state

**Files:**
- Modify: `whatsub-mobile/Networking/DTOs.swift`
- Modify: `whatsub-mobile/App/AppState.swift`
- Modify: `whatsub-mobileTests/DTOTests.swift`
- Create: `whatsub-mobileTests/LlmEntitlementStateTests.swift`

**Interfaces:**
- Produces: `LlmEntitlements`, `MeResponse.llmEntitlements`, `AppState.effectiveLlmEntitlements`

- [ ] **Step 1: Add failing decode/logout tests**

```swift
func testMeDecodesBuyoutProCapabilities() throws {
    let me = try decodeMe(#"{"email":"a@x.com","hasActiveLicense":true,"llmEntitlements":{"tier":"buyout_pro","managedRelay":true,"byok":true,"tokenTopups":true}}"#)
    XCTAssertEqual(me.llmEntitlements?.tier, .buyoutPro)
    XCTAssertEqual(me.llmEntitlements?.byok, true)
}

@MainActor func testLogoutClearsLastKnownCapabilities() {
    let state = AppState(); state.installFixtureEntitlements(.buyout)
    state.logout()
    XCTAssertNil(state.effectiveLlmEntitlements)
}
```

- [ ] **Step 2: Run and prove types are missing**

Run the existing iOS test command filtered to `DTOTests` and `LlmEntitlementStateTests`.

- [ ] **Step 3: Add backward-compatible decoding**

```swift
struct LlmEntitlements: Decodable, Equatable {
    enum Tier: String, Decodable { case free, buyout, pro; case buyoutPro = "buyout_pro" }
    let tier: Tier
    let managedRelay: Bool
    let byok: Bool
    let tokenTopups: Bool
}
```

Keep last-known capabilities only while the same session email remains active. Missing field from an old backend never grants a new BYOK entitlement.

- [ ] **Step 4: Run and commit**

```bash
git add whatsub-mobile/Networking/DTOs.swift whatsub-mobile/App/AppState.swift whatsub-mobileTests/DTOTests.swift whatsub-mobileTests/LlmEntitlementStateTests.swift
git commit -m "feat(auth): sync iOS LLM entitlements"
```

### Task 2: Enforce mode policy without deleting keys

**Files:**
- Create: `whatsub-mobile/LLM/LlmEntitlementPolicy.swift`
- Create: `whatsub-mobileTests/LlmEntitlementPolicyTests.swift`
- Modify: `whatsub-mobile/LLM/LlmSettings.swift`
- Modify: `whatsub-mobile/LLM/ChatCompletionsClient.swift`

**Interfaces:**
- Produces: `allowedModes`, `effectiveSettings`, `validateCall`

- [ ] **Step 1: Write four-state policy tests**

```swift
func testPersistedBYOKIsCoercedForProButNotDeleted() throws {
    let stored = fixtureSettings(useManagedRelay: false, apiKey: "sk-secret")
    let effective = try LlmEntitlementPolicy.effectiveSettings(stored, entitlements: .pro)
    XCTAssertTrue(effective.useManagedRelay)
    XCTAssertEqual(stored.apiKey, "sk-secret")
}

func testFreeBYOKFailsBeforeNetwork() async {
    do {
        _ = try await client.call(settings: byokSettings, entitlements: .free)
        XCTFail("expected byokNotEntitled")
    } catch LlmEntitlementError.byokNotEntitled {
        // Expected: the policy rejected before URLSession.
    } catch {
        XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(urlProtocol.requestCount, 0)
}
```

- [ ] **Step 2: Run and prove policy is missing**

Run tests filtered to `LlmEntitlementPolicyTests`.

- [ ] **Step 3: Add typed denial before secret access**

Add `LlmMode.managedRelay/byok` and `LlmEntitlementError.byokNotEntitled`. `ChatCompletionsClient` validates before reading `apiKey` or constructing a direct URL.

- [ ] **Step 4: Run and commit**

```bash
git add whatsub-mobile/LLM/LlmEntitlementPolicy.swift whatsub-mobile/LLM/LlmSettings.swift whatsub-mobile/LLM/ChatCompletionsClient.swift whatsub-mobileTests/LlmEntitlementPolicyTests.swift
git commit -m "feat(llm): gate iOS BYOK by buyout"
```

### Task 3: Render account-specific LLM settings and errors

**Files:**
- Modify: `whatsub-mobile/LLM/LlmSettingsView.swift`
- Create: `whatsub-mobileTests/LlmSettingsEntitlementPresentationTests.swift`
- Modify: `whatsub-mobile/Import/ImportView.swift`
- Modify: `whatsub-mobile/App/RemoteFailure.swift`

- [ ] **Step 1: Write presentation matrix tests**

```swift
func testProPresentationHasRelayButNoKeyFields() {
    let model = LlmSettingsPresentation(entitlements: .pro, storedMode: .byok)
    XCTAssertEqual(model.availableModes, [.managedRelay])
    XCTAssertFalse(model.showsAPIKeyFields)
}
func testBuyoutProOffersBothModes() {
    XCTAssertEqual(LlmSettingsPresentation(entitlements: .buyoutPro, storedMode: .byok).availableModes,
                   [.managedRelay, .byok])
}
```

- [ ] **Step 2: Run and prove current unrestricted toggle fails**

Run tests filtered to `LlmSettingsEntitlementPresentationTests`.

- [ ] **Step 3: Replace unrestricted controls and stale copy**

Free/Pro show relay quota only; buyout shows BYOK only; both show a two-mode picker. Remove unconditional “使用自己的 API Key” from free-used-up, duration, and Pro quota screens.

- [ ] **Step 4: Run and commit**

```bash
git add whatsub-mobile/LLM/LlmSettingsView.swift whatsub-mobile/Import/ImportView.swift whatsub-mobile/App/RemoteFailure.swift whatsub-mobileTests/LlmSettingsEntitlementPresentationTests.swift whatsub-mobileTests/ImportManagedAnalysisTests.swift
git commit -m "feat(settings): present entitled iOS LLM modes"
```

### Task 4: Add wallet DTOs and API client

**Files:**
- Modify: `whatsub-mobile/Networking/DTOs.swift`
- Modify: `whatsub-mobile/Networking/WhatsubAPI.swift`
- Create: `whatsub-mobileTests/TokenWalletAPITests.swift`

**Interfaces:**
- Produces: `TokenTopupProduct`, `TokenWallet`, `TokenTransaction`, catalog/wallet/history/verify methods

- [ ] **Step 1: Write failing verification test**

```swift
func testVerifyTokenPurchasePostsOnlyJWS() async throws {
    let api = makeAPI(response: #"{"kind":"token_topup","credited":true,"topupBalance":1000000}"#)
    let result = try await api.verifyTokenPurchase(token: "session", signedTransactionInfo: "jws")
    XCTAssertEqual(result.topupBalance, 1_000_000)
    XCTAssertEqual(decodedBody.keys.sorted(), ["signedTransactionInfo"])
}
```

- [ ] **Step 2: Run and prove methods are missing**

Run tests filtered to `TokenWalletAPITests`.

- [ ] **Step 3: Implement exact wire models**

Never send client Token amounts/prices during verification. All wallet reads use bearer auth.

- [ ] **Step 4: Run and commit**

```bash
git add whatsub-mobile/Networking/DTOs.swift whatsub-mobile/Networking/WhatsubAPI.swift whatsub-mobileTests/TokenWalletAPITests.swift
git commit -m "feat(llm): add iOS token wallet API"
```

### Task 5: Purchase consumables safely

**Files:**
- Create: `whatsub-mobile/Store/TokenTopupStore.swift`
- Modify: `whatsub-mobile/Store/StoreManager.swift`
- Create: `whatsub-mobileTests/TokenTopupStoreTests.swift`

**Interfaces:**
- Produces: product loading, `purchase(product:)`, unfinished-transaction processing

- [ ] **Step 1: Write failing finish-after-credit test**

```swift
func testDoesNotFinishUntilBackendCredits() async {
    let transaction = TransactionSpy(productID: "whatsub_token_1m")
    api.creditResult = .failure(NetworkError.offline)
    XCTAssertFalse(await store.process(transaction)); XCTAssertEqual(transaction.finishCount, 0)
    api.creditResult = .success(.init(credited: true, topupBalance: 1_000_000))
    XCTAssertTrue(await store.process(transaction)); XCTAssertEqual(transaction.finishCount, 1)
}
```

- [ ] **Step 2: Run and prove store is missing**

Run tests filtered to `TokenTopupStoreTests`.

- [ ] **Step 3: Implement StoreKit separation**

```swift
static let productIDs: Set<String> = ["whatsub_token_1m", "whatsub_token_5m", "whatsub_token_15m"]
```

Use the subscription appAccountToken. Await backend credit before `finish()`. On backend failure leave unfinished for `Transaction.updates` redelivery. Do not include consumables in current-entitlements restore.

- [ ] **Step 4: Test pending/cancelled/duplicate/account mismatch**

Backend `{credited:false}` with current balance is safe to finish; pending/cancelled are not. Reject mismatched appAccountToken.

- [ ] **Step 5: Run and commit**

```bash
git add whatsub-mobile/Store/TokenTopupStore.swift whatsub-mobile/Store/StoreManager.swift whatsub-mobileTests/TokenTopupStoreTests.swift
git commit -m "feat(store): purchase token consumables"
```

### Task 6: Add top-up sheet and quota panel

**Files:**
- Create: `whatsub-mobile/Store/TokenTopupSheet.swift`
- Modify: `whatsub-mobile/Store/SubscriptionOptionsView.swift`
- Modify: `whatsub-mobile/Me/MeView.swift`
- Create: `whatsub-mobileTests/TokenTopupPresentationTests.swift`

- [ ] **Step 1: Write presentation tests**

```swift
func testPacksAppearOnlyForActivePro() {
    XCTAssertFalse(TokenTopupPresentation(entitlements: .free, wallet: nil).isAvailable)
    XCTAssertEqual(TokenTopupPresentation(entitlements: .pro, wallet: wallet).packTokens,
                   [1_000_000, 5_000_000, 15_000_000])
}
```

- [ ] **Step 2: Run and prove model is missing**

Run tests filtered to `TokenTopupPresentationTests`.

- [ ] **Step 3: Implement localized StoreKit UI**

Show monthly usage, recharge balance, reset date, latest recharge transactions, frozen explanation, and StoreKit `displayPrice`. Show 80% warning without interruption; present purchase after quota error or explicit quota-row tap.

- [ ] **Step 4: Run and commit**

```bash
git add whatsub-mobile/Store/TokenTopupSheet.swift whatsub-mobile/Store/SubscriptionOptionsView.swift whatsub-mobile/Me/MeView.swift whatsub-mobileTests/TokenTopupPresentationTests.swift
git commit -m "feat(store): show Pro token topups"
```

### Task 7: Resume paused analysis after purchase

**Files:**
- Modify: `whatsub-mobile/Import/ImportView.swift`
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Modify: `whatsub-mobile/Me/ImportQueueView.swift`
- Modify: `whatsub-mobile/Library/ProgressiveAnalysisOverlay.swift`
- Modify: `whatsub-mobile/App/AppState.swift`
- Modify: `whatsub-mobileTests/ImportManagedAnalysisTests.swift`
- Modify: `whatsub-mobileTests/PendingManagedAnalysisCoordinatorTests.swift`

- [ ] **Step 1: Add failing resume test**

```swift
@MainActor func testTopupRefreshesWalletAndResumesFromCheckpoint() async {
    let vm = makePausedViewModel(completedCues: 73, totalCues: 150)
    walletAPI.nextBalance = 1_000_000
    await vm.handleTopupSuccess(token: "session")
    XCTAssertEqual(managedAPI.resumeCalls, 1)
    XCTAssertEqual(vm.job?.completedCues, 73)
}
```

- [ ] **Step 2: Run and prove no auto-resume**

Run filtered Import/Pending coordinator tests.

- [ ] **Step 3: Add purchase-origin and capacity guard**

Remember the paused job ID. After purchase, refresh `/me` and wallet; resume only if it remains `pausedQuota` and capacity increased. Never resume cancelled, format-failed, or running jobs.

- [ ] **Step 4: Render entitlement-specific recovery**

Free: subscribe; Pro: top-up/wait; buyout + Pro: top-up/BYOK/wait. Preserve checkpoint copy on Import, queue, and Library overlay.

- [ ] **Step 5: Run and commit**

```bash
git add whatsub-mobile/Import/ImportView.swift whatsub-mobile/Import/ImportViewModel.swift whatsub-mobile/Me/ImportQueueView.swift whatsub-mobile/Library/ProgressiveAnalysisOverlay.swift whatsub-mobile/App/AppState.swift whatsub-mobileTests/ImportManagedAnalysisTests.swift whatsub-mobileTests/PendingManagedAnalysisCoordinatorTests.swift
git commit -m "feat(analysis): resume iOS jobs after purchase"
```

### Task 8: StoreKit configuration and TestFlight

**Files:**
- Modify: `whatsub-mobile/project.yml`
- Modify: `whatsub-mobile/AGENTS.md`
- Create: `whatsub-mobile/StoreKit/TokenTopups.storekit` if no configuration exists

- [ ] **Step 1: Add privacy-safe funnel events**

Track quota wall, top-up sheet, pack choice, result, and resume result. Include product/tier/status only; never Key, subtitle, prompt, JWS, or transaction ID.

- [ ] **Step 2: Create three App Store Connect consumables**

Use exact IDs and China prices ¥10/¥45/¥125. Add localized names/descriptions and mirror IDs in local StoreKit configuration.

- [ ] **Step 3: Require full CI**

Push feature branch and require simulator build, all tests, install, and screenshot artifact to pass.

- [ ] **Step 4: Test sandbox edge cases**

Test four account tiers, cancellation, pending, network loss after Apple success, relaunch redelivery, duplicate verification, Pro expiry race, and checkpoint resume.

- [ ] **Step 5: Commit and release in dependency order**

```bash
git add project.yml AGENTS.md StoreKit/TokenTopups.storekit
git commit -m "docs: configure iOS token topups"
```

Ship TestFlight only after backend, website, and desktop staging. Keep catalog disabled until sandbox passes, then enable and submit. Never expose website payment links in iOS.
