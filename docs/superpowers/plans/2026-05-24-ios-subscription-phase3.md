# iOS Subscription (Phase 3) + Quota Flip — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an App-Store-compliant iOS subscription (月 ¥12 / 年 ¥88) for license holders that unlocks the 50 cloud-video quota, and flip the backend quota from license-gated to subscription-gated (`iosSubActive ? 50 : 3`).

**Architecture:** Backend changes one helper (`quotaLimit`) to source `iosSubActive` from `getIosEntitlements` locally in the 3 library quota handlers — the subscription verify/notification plumbing already ships. iOS extends `StoreManager` to sell the two subscription products, adds a shared `SubscriptionOptionsView`, wires it into a license-only MeView section (passive) and an import quota-wall body (active, auto-retries the push on subscribe).

**Tech Stack:** Backend = Hono + Postgres (pg-mem tests, Vitest); iOS = Swift 5.10 + SwiftUI + StoreKit 2 (no local compile on Windows — CI builds, TestFlight sandbox verifies).

---

## Two repos, one coupled release

- **Backend:** `C:\Users\renjx\Desktop\whatsub-license` — branch `feat/ios-sub-quota`. Locally testable (`pnpm test`, `pnpm typecheck`).
- **iOS:** `C:\Users\renjx\Desktop\whatsub-mobile` — branch `feat/ios-subscription`. **Cannot compile on Windows** — every iOS task's "verify" is deferred to CI (Part C). No `xcodebuild` step here.

⚠️ **Ship together (Part C).** Deploying the backend flip alone drops every license user (incl. the owner) to 3 with no way back to 50 until the iOS subscription UI is live. Do not push iOS to TestFlight or deploy the backend until both Parts A and B are committed and reviewed. Both Part-C actions (TestFlight push, prod deploy) require explicit owner authorization.

## File Structure

**Backend (`whatsub-license`):**
- Modify `src/routes/library.ts` — `quotaLimit` → async `quotaLimitFor(email)` using `iosSubActive`; update 3 call sites.
- Modify `tests/library-routes.test.ts` — add a `quota tiers (iosSubActive)` describe block.

**iOS (`whatsub-mobile`):**
- Modify `whatsub-mobile/Store/StoreManager.swift` — load 2 sub products + `purchaseSubscription` + `hasLocalSub`.
- Create `whatsub-mobile/Store/SubscriptionOptionsView.swift` — shared month/year purchase UI.
- Modify `whatsub-mobile/Me/MeView.swift` — license-only subscription section.
- Modify `whatsub-mobile/Networking/APIError.swift` — `.quotaExceeded(used:limit:)` case.
- Modify `whatsub-mobile/Networking/DTOs.swift` — `QuotaErrorBody`.
- Modify `whatsub-mobile/Networking/WhatsubAPI.swift` — `send` throws `.quotaExceeded` on 403.
- Modify `whatsub-mobile/Import/ImportViewModel.swift` — `.quotaWall(used:limit:)` state.
- Modify `whatsub-mobile/Import/ImportView.swift` — quota-wall body + `@EnvironmentObject store`.
- Modify `whatsub-mobile/App/WhatsubMobileApp.swift` — inject `store` into the ImportView sheet.

`project.yml` build number is **not** touched — `testflight.yml` CI assigns the build number on the `main` push (see `project.yml:105-108`).

---

# PART A — Backend quota flip (whatsub-license)

> Run all commands from `C:\Users\renjx\Desktop\whatsub-license`. Create the branch first:
> `git checkout -b feat/ios-sub-quota`

## Task A1: Flip `quotaLimit` to source `iosSubActive`

**Files:**
- Modify: `src/routes/library.ts:9-10` (the `quotaLimit` helper) + call sites at `:51`, `:94`, `:128`
- Test: `tests/library-routes.test.ts` (append a new describe block)

Context (already verified): `db.getIosEntitlements(email, now)` returns `{ iosBuyout, iosSubActive, subProductId, trialExpiresAt }` where `iosSubActive = sub_expires_at != null && sub_expires_at > now` (`src/lib/db.ts:1981`). `db.setSubscription(email, expiresAt, productId, txnId, now)` seeds an active subscription (`src/lib/db.ts:2024`). `db.insertLicense({ key, max_devices, created_at, buyer_note, email })` seeds a license. No route-level quota test exists today, so this flip breaks no existing test.

- [ ] **Step 1: Write the failing tests**

Append to `tests/library-routes.test.ts` (after the last `describe`):

```ts
describe('quota tiers (iosSubActive, not license)', () => {
  async function seedActiveSub(db: Database, email: string) {
    // setSubscription(email, expiresAt, productId, txnId, now)
    await db.setSubscription(email, Date.now() + 30 * 24 * 3600_000, 'whatsub_pro_month', `txn-${email}`, Date.now());
  }
  async function seedVideos(db: Database, email: string, ids: string[]) {
    for (const id of ids) {
      await db.upsertLibraryEntry({
        id, ownerEmail: email, youtubeId: id, sourceUrl: 'https://x/' + id,
        title: 't', transcriptSrt: 's', analysisJson: {}, videoKey: 'k-' + id, now: 1,
      });
    }
  }

  it('GET /quota: no entitlement → limit 3', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'free@x.com');
    const res = await rig.app.request('/api/library/quota', { headers: { authorization: `Bearer ${token}` } });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { limit: number }).limit).toBe(3);
  });

  it('GET /quota: active subscription → limit 50', async () => {
    const rig = makeApp();
    await seedActiveSub(rig.db, 'sub@x.com');
    const token = await insertSessionFor(rig.db, 'sub@x.com');
    const res = await rig.app.request('/api/library/quota', { headers: { authorization: `Bearer ${token}` } });
    expect(((await res.json()) as { limit: number }).limit).toBe(50);
  });

  it('GET /quota: license WITHOUT subscription → limit 3 (license alone no longer grants 50)', async () => {
    const rig = makeApp();
    await rig.db.insertLicense({ key: 'WHATSUB-AAAA-BBBB-CCCC-DDDD', max_devices: 3, created_at: 1, buyer_note: null, email: 'lic@x.com' });
    const token = await insertSessionFor(rig.db, 'lic@x.com');
    const res = await rig.app.request('/api/library/quota', { headers: { authorization: `Bearer ${token}` } });
    expect(((await res.json()) as { limit: number }).limit).toBe(3);
  });

  it('POST /import-queue: 4th push over the free limit → 403 quota_exceeded {used, limit}', async () => {
    const rig = makeApp();
    await seedVideos(rig.db, 'full@x.com', ['a', 'b', 'c']);
    const token = await insertSessionFor(rig.db, 'full@x.com');
    const res = await rig.app.request('/api/library/import-queue', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: 'https://youtu.be/d' }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: string; used: number; limit: number };
    expect(body.error).toBe('quota_exceeded');
    expect(body.limit).toBe(3);
    expect(body.used).toBe(3);
  });

  it('POST /import-queue: subscriber can push beyond 3 (limit 50)', async () => {
    const rig = makeApp();
    await seedActiveSub(rig.db, 'subpush@x.com');
    await seedVideos(rig.db, 'subpush@x.com', ['a', 'b', 'c']);
    const token = await insertSessionFor(rig.db, 'subpush@x.com');
    const res = await rig.app.request('/api/library/import-queue', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: 'https://youtu.be/d' }),
    });
    expect(res.status).toBe(200);
  });

  it('POST /sync: 4th videoKey entry over the free limit → 403', async () => {
    const rig = makeApp();
    await seedVideos(rig.db, 'syncfull@x.com', ['a', 'b', 'c']);
    const token = await insertSessionFor(rig.db, 'syncfull@x.com');
    const res = await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'd', videoKey: 'whatsub/library/x/d.mp4' }),
    });
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: string }).error).toBe('quota_exceeded');
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm vitest run tests/library-routes.test.ts -t "quota tiers"`
Expected: FAIL — `active subscription → limit 50` gets 3, `license WITHOUT subscription → limit 3` gets 50, `subscriber can push beyond 3` gets 403. (The free-tier guard tests pass already.)

- [ ] **Step 3: Implement the flip**

In `src/routes/library.ts`, replace the helper (`:9-10`):

```ts
  const quotaLimitFor = async (email: string) => {
    const ent = await db.getIosEntitlements(email, Date.now());
    return ent.iosSubActive ? 50 : 3;
  };
```

Then update the three call sites:
- `:51` (inside `POST /sync`): `const limit = quotaLimit(c);` → `const limit = await quotaLimitFor(email);`
- `:94` (inside `GET /quota`): `return c.json({ used, limit: quotaLimit(c) });` → `return c.json({ used, limit: await quotaLimitFor(email) });`
- `:128` (inside `POST /import-queue`): `const limit = quotaLimit(c);` → `const limit = await quotaLimitFor(email);`

`email` is already in scope at each site (`const email = c.get('email' as never) as string`). Remove the now-unused old `quotaLimit`.

- [ ] **Step 4: Run the new tests + the full suite + typecheck**

Run: `pnpm vitest run tests/library-routes.test.ts -t "quota tiers"`
Expected: PASS (6 tests).

Run: `pnpm test`
Expected: all green (was 373+; +6 new).

Run: `pnpm typecheck`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "feat(library): quota tier from iosSubActive (50) instead of license (Phase 3)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

Do **not** push or deploy yet — Part C ships this with the iOS build.

---

# PART B — iOS subscription UI (whatsub-mobile)

> Run all commands from `C:\Users\renjx\Desktop\whatsub-mobile`. Create the branch first:
> `git checkout -b feat/ios-subscription`
>
> **No local compile.** Each task ends with a commit; compilation is verified by CI after the Part-C push. Write the code exactly as given.

## Task B1: StoreManager — load subscription products + purchaseSubscription

**Files:**
- Modify: `whatsub-mobile/Store/StoreManager.swift`

- [ ] **Step 1: Add product IDs + published products**

Below `static let buyoutProductID = "cc.eversay.whatsub.mobile.fullunlock"`:

```swift
    static let subMonthID = "whatsub_pro_month"
    static let subYearID  = "whatsub_pro_year"
```

Below `@Published var hasLocalBuyout = false`:

```swift
    @Published var subMonth: Product?
    @Published var subYear: Product?
    /// Offline-capable: StoreKit shows a current (non-expired) subscription on this device.
    @Published var hasLocalSub = false
```

- [ ] **Step 2: Load all three products**

Replace the whole `loadProducts()` body:

```swift
    func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.buyoutProductID, Self.subMonthID, Self.subYearID])
            for p in products {
                switch p.id {
                case Self.buyoutProductID: buyoutProduct = p
                case Self.subMonthID:      subMonth = p
                case Self.subYearID:       subYear = p
                default: break
                }
            }
        } catch {
            lastError = "无法加载商品，请检查网络后重试"
        }
    }
```

- [ ] **Step 3: Refactor purchase into a shared method + add purchaseSubscription**

Replace the whole `purchaseBuyout()` method with:

```swift
    /// Buy the buyout. Returns true if the purchase verified successfully.
    func purchaseBuyout() async -> Bool { await purchase(buyoutProduct) }

    /// Buy a subscription (month or year). Same verify→report→refresh path as buyout.
    func purchaseSubscription(_ product: Product) async -> Bool { await purchase(product) }

    private func purchase(_ product: Product?) async -> Bool {
        guard let product else {
            lastError = "商品未就绪，请稍后重试"
            return false
        }
        lastError = nil
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                return await process(verification)
            case .userCancelled:
                return false
            case .pending:
                lastError = "购买待确认"
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "购买失败：\(error.localizedDescription)"
            return false
        }
    }
```

- [ ] **Step 4: Track local subscription entitlement**

Replace the whole `refreshLocalEntitlements()` body:

```swift
    private func refreshLocalEntitlements() async {
        var buyout = false
        var sub = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result {
                if t.productID == Self.buyoutProductID { buyout = true }
                if t.productID == Self.subMonthID || t.productID == Self.subYearID { sub = true }
            }
        }
        hasLocalBuyout = buyout
        hasLocalSub = sub
    }
```

(The `Transaction.updates` listener and `restore()` already report every verified entitlement to the backend — they need no change; the new sub products flow through them automatically.)

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Store/StoreManager.swift
git commit -m "feat(ios/store): load month/year subscription products + purchaseSubscription

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## Task B2: SubscriptionOptionsView — shared purchase UI

**Files:**
- Create: `whatsub-mobile/Store/SubscriptionOptionsView.swift`

This view is added to `project.yml`'s `whatsub-mobile` target automatically — it lives under `whatsub-mobile/Store/` which is already globbed by the `sources` entry (no `project.yml` edit needed; XcodeGen picks up new files under the source root).

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import StoreKit

/// Shared subscription purchase UI: month/year buttons + 恢复购买 + the Apple-
/// required auto-renew disclosure + 隐私/EULA links. The CALLER decides whether to
/// show it (license-only); this view just sells. `onPurchased` fires after a
/// successful subscribe so callers can refresh quota or retry a blocked action.
struct SubscriptionOptionsView: View {
    @EnvironmentObject var store: StoreManager
    var onPurchased: (() -> Void)?

    private let privacyURL = URL(string: "https://whatsub.eversay.cc/privacy")!
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let m = store.subMonth { planButton(m, label: "包月", note: "¥12/月") }
            if let y = store.subYear { planButton(y, label: "包年", note: "¥88/年 · 更划算") }

            if let err = store.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }

            Button("恢复购买") { Task { await store.restore() } }
                .font(.callout).foregroundStyle(.whatsubInkMuted)

            Text("订阅自动续订，可随时在「设置 › Apple ID › 订阅」中取消。")
                .font(.caption2).foregroundStyle(.whatsubInkFaint)

            HStack(spacing: 16) {
                Link("隐私政策", destination: privacyURL)
                Link("服务条款", destination: termsURL)
            }
            .font(.caption2).foregroundStyle(.whatsubInkFaint)
        }
        .onAppear { store.start() }
    }

    private func planButton(_ product: Product, label: String, note: String) -> some View {
        Button {
            Task { if await store.purchaseSubscription(product) { onPurchased?() } }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(label) · \(product.displayPrice)").fontWeight(.semibold)
                    Text(note).font(.caption).foregroundStyle(.black.opacity(0.7))
                }
                Spacer()
                if store.purchaseInProgress {
                    ProgressView().tint(.black)
                } else {
                    Text("升级到 50").fontWeight(.semibold)
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Color.whatsubAccent)
            .foregroundColor(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(store.purchaseInProgress)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Store/SubscriptionOptionsView.swift
git commit -m "feat(ios/store): shared SubscriptionOptionsView (month/year + restore + disclosure)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## Task B3: MeView — license-only subscription section

**Files:**
- Modify: `whatsub-mobile/Me/MeView.swift`

- [ ] **Step 1: Add the StoreKit import + StoreManager + manage-subscription state**

At the top of `MeView.swift`, add `import StoreKit` below `import SwiftUI` (required for `.manageSubscriptionsSheet`).

Below `@State private var quota: LibraryQuota?` (`MeView.swift:5`):

```swift
    @EnvironmentObject var store: StoreManager
    @State private var showManageSubscriptions = false
```

(MeView is a tab inside `mainTabs`, which already has `store` in the environment via `ContentView` — no re-injection needed.)

- [ ] **Step 2: Replace the 云端同步 section**

Replace the whole `Section("云端同步") { … }` block (`MeView.swift:25-34`) with:

```swift
                    Section("云端同步") {
                        if let q = quota {
                            LabeledContent("云端视频", value: "\(q.used)/\(q.limit)")
                                .foregroundStyle(.whatsubInk)
                        }
                        if appState.currentUser?.hasActiveLicense == true {
                            if appState.currentUser?.iosSubActive == true {
                                Label("已订阅 · \(subPlanName)", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(.whatsubAccent)
                                Button("管理订阅") { showManageSubscriptions = true }
                                    .foregroundStyle(.whatsubAccent)
                            } else {
                                Text("订阅解锁 50 个云端视频额度。")
                                    .font(.footnote).foregroundStyle(.whatsubInkMuted)
                                SubscriptionOptionsView(onPurchased: { Task { await reloadQuota() } })
                                    .padding(.vertical, 4)
                            }
                        } else {
                            Text("免费 3 个云端视频。开通网站授权后可订阅解锁 50 个；需要手机端公共语料库也请在官网用同一邮箱开通授权后回到这里登录。")
                                .font(.footnote).foregroundStyle(.whatsubInkMuted)
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                    .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
```

- [ ] **Step 3: Add the plan-name helper + reloadQuota, and extract the quota load**

Add these computed/helper members to `MeView` (e.g. just after `versionString`):

```swift
    private var subPlanName: String {
        // `subProductId` is String?; plain == avoids switch-on-optional pattern subtleties.
        let pid = appState.currentUser?.subProductId
        if pid == StoreManager.subMonthID { return "包月" }
        if pid == StoreManager.subYearID { return "包年" }
        return "已订阅"
    }

    private func reloadQuota() async {
        await appState.refreshMe()
        if let t = appState.session?.sessionToken {
            quota = try? await WhatsubAPI.shared.libraryQuota(token: t)
        }
    }
```

Then change the `.task` block (`MeView.swift:83-88`) to reuse it:

```swift
            .task { await reloadQuota() }
```

- [ ] **Step 4: Commit**

```bash
git add whatsub-mobile/Me/MeView.swift
git commit -m "feat(ios/me): license-only subscription section (¥12月/¥88年 + manage)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## Task B4: API — detect quota_exceeded (403) with used/limit

**Files:**
- Modify: `whatsub-mobile/Networking/APIError.swift`
- Modify: `whatsub-mobile/Networking/DTOs.swift`
- Modify: `whatsub-mobile/Networking/WhatsubAPI.swift`

- [ ] **Step 1: Add the APIError case**

In `APIError.swift`, add the case (after `case badInput(String)`):

```swift
    case quotaExceeded(used: Int, limit: Int)   // 403 from library sync/push — over the OSS-video cap
```

And add its message in the `chinese` switch (a top-level case, alongside `.network`/`.server`/…):

```swift
        case .quotaExceeded(let used, let limit):
            return "云端视频已达上限（\(used)/\(limit)）"
```

- [ ] **Step 2: Add the quota error body DTO**

In `DTOs.swift`, after `struct ErrorResponse: Decodable { let error: String? }` (`:47`):

```swift
/// 403 quota_exceeded body from POST /sync and /import-queue: { error, used, limit }.
struct QuotaErrorBody: Decodable { let error: String?; let used: Int?; let limit: Int? }
```

- [ ] **Step 3: Throw `.quotaExceeded` from `send`**

In `WhatsubAPI.swift`, in `send(_:)`, replace the non-2xx guard body (`:241-244`):

```swift
        guard (200..<300).contains(http.statusCode) else {
            let err = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if http.statusCode == 403, err?.error == "quota_exceeded" {
                let q = try? JSONDecoder().decode(QuotaErrorBody.self, from: data)
                throw APIError.quotaExceeded(used: q?.used ?? 0, limit: q?.limit ?? 0)
            }
            throw APIError.server(http.statusCode, err?.error)
        }
```

(The old `.server(403, "quota_exceeded")` → "云端视频已达上限…" string mapping in `APIError.chinese` stays as a harmless fallback.)

- [ ] **Step 4: Commit**

```bash
git add whatsub-mobile/Networking/APIError.swift whatsub-mobile/Networking/DTOs.swift whatsub-mobile/Networking/WhatsubAPI.swift
git commit -m "feat(ios/api): surface quota_exceeded as APIError.quotaExceeded(used,limit)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## Task B5: Import quota-wall body + auto-retry + sheet env injection

**Files:**
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Modify: `whatsub-mobile/Import/ImportView.swift`
- Modify: `whatsub-mobile/App/WhatsubMobileApp.swift`

- [ ] **Step 1: Add the `.quotaWall` state + catch it in pushToDesktop**

In `ImportViewModel.swift`, add a case to the `State` enum (after `case needsDesktop(message: String)`):

```swift
        /// Push blocked by the OSS-video quota cap. Carries used/limit for display
        /// + the license-holder upsell.
        case quotaWall(used: Int, limit: Int)
```

In `pushToDesktop(token:)`, replace the `catch` chain (`ImportViewModel.swift:121-125`):

```swift
        } catch APIError.quotaExceeded(let used, let limit) {
            state = .quotaWall(used: used, limit: limit)
        } catch let e as APIError {
            state = .error(e.chinese)
        } catch {
            state = .error(error.localizedDescription)
        }
```

- [ ] **Step 2: Render the quota-wall body in ImportView**

In `ImportView.swift`, add `store` to the view (after `@EnvironmentObject var appState: AppState`, `:4`):

```swift
    @EnvironmentObject var store: StoreManager
```

Add the new state case to the `switch vm.state` (after `case .pushedToDesktop:`, `:52-53`):

```swift
            case .quotaWall(let used, let limit):
                quotaWallBody(used: used, limit: limit)
```

Add the body builder (e.g. after `pushedToDesktopBody`, before `// MARK: - Actions`):

```swift
    // MARK: - Quota wall (over cloud-video cap)

    private func quotaWallBody(used: Int, limit: Int) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "icloud.slash")
                .font(.system(size: 48))
                .foregroundStyle(.whatsubHighlight)
            Text("云端视频已达上限")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
            Text("已用 \(used)/\(limit) 个云端视频。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)

            if appState.currentUser?.hasActiveLicense == true {
                Text("订阅解锁 50 个云端额度，订阅成功会自动继续这次推送。")
                    .font(.subheadline)
                    .foregroundStyle(.whatsubInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                SubscriptionOptionsView(onPurchased: {
                    guard let token = appState.session?.sessionToken else { return }
                    Task { await vm.pushToDesktop(token: token) }
                })
                .padding(.horizontal)
            } else {
                Text("先在 Library 删一个，或在官网用同一邮箱购买授权后再订阅。")
                    .font(.subheadline)
                    .foregroundStyle(.whatsubInkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("完成") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.whatsubAccent)
                .padding(.top, 4)
            Spacer()
        }
        .padding()
    }
```

(`vm.pushToDesktop` reuses the VM's retained `resolvedSourceURL`/`videoId`, so the retry re-pushes the same URL. After a successful subscribe the backend reports `iosSubActive=true` and quota = 50, so the retry passes and transitions to `.pushedToDesktop`.)

- [ ] **Step 3: Inject `store` into the ImportView sheet**

`ImportView` now requires `StoreManager` in its environment. The MeView `NavigationLink(destination: ImportView())` path already has it (MeView is inside `mainTabs`), but the deep-link sheet re-injects only `appState`. In `WhatsubMobileApp.swift`, update the `.sheet(item: $pendingImport)` block (`:126-131`):

```swift
        .sheet(item: $pendingImport) { item in
            NavigationStack {
                ImportView(initialURL: item.url)
                    .environmentObject(appState)
                    .environmentObject(store)
            }
        }
```

- [ ] **Step 4: Commit**

```bash
git add whatsub-mobile/Import/ImportViewModel.swift whatsub-mobile/Import/ImportView.swift whatsub-mobile/App/WhatsubMobileApp.swift
git commit -m "feat(ios/import): quota-wall upsell (license holders) + auto-retry push on subscribe

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# PART C — Integration, deploy, sandbox verify (owner-authorized)

> Both push actions burn resources / go live — **get explicit owner authorization before each.** Backend `pnpm test` must be green (Part A) before any of this.

- [ ] **C1 — Push iOS to TestFlight (owner-authorized).** Merge `feat/ios-subscription` → `main` in `whatsub-mobile` and push. `testflight.yml` builds + signs + assigns the build number + uploads. Watch the run: `gh run watch --repo rjxznb/whatsub-mobile`. This is where Swift compilation is first verified — if it fails, fix and re-push. (Cert-slot gotcha: if Archive fails with "maximum number of certificates", revoke old Apple Distribution certs at developer.apple.com, then `gh run rerun <id>`.) This push also carries any parked doc commits + the `feat/me-link-text` parking if still relevant.

- [ ] **C2 — Deploy the backend flip (owner-authorized).** Merge `feat/ios-sub-quota` → `main` in `whatsub-license`; build + ship the image per `whatsub-license/CLAUDE.md` "Build + deploy" (local `docker buildx build --load` → save → scp → `docker load` → `docker compose --env-file .env up -d --force-recreate` on `47.93.87.206`). No schema/env change this time (entitlement table + Apple env already live). Smoke: `GET /api/license/library/quota` for a logged-in non-subscriber returns `limit:3`.

- [ ] **C3 — Sandbox-test on TestFlight build (owner, real device).**
  - As a **license holder, not subscribed**: open 我的 → 云端同步 shows `used/limit` with limit 3 + the 包月/包年 buttons. Buy 包月 with a **Sandbox Apple ID** → after verify, the section flips to "已订阅 · 包月" and limit becomes 50.
  - **Wall + auto-retry:** as a license holder at 3/3, 导入 a 4th video → "推送到桌面端" → quota-wall screen → subscribe in-place → push auto-continues to "已推送到桌面端".
  - **恢复购买:** delete + reinstall → 我的 → 恢复购买 → "已订阅" returns.
  - **管理订阅:** the 管理订阅 row opens the system subscription sheet.
  - **Non-license user:** 云端同步 shows only the free-3 text, no purchase buttons; hitting the cap shows the plain message (no upsell).

- [ ] **C4 — Update docs/memory.** Append a Phase-3-shipped note to `CLAUDE.md` (kept LOCAL per the doc-push convention), and update the `feedback-monetization-oss-quota` + `project-roadmap` memories (Phase 3 done; quota now `iosSubActive?50:3`).

---

## Self-Review (done while writing)

**Spec coverage:** §1 quota flip → Task A1. §2 StoreManager → B1. §3 MeView section → B3. §4 wall-hit upsell + auto-retry → B5. §C SubscriptionOptionsView → B2. Compliance disclosure/links → B2. Rollout coupling → Part C header + C1/C2. Manage-subscription (iOS 16+) → B3 `manageSubscriptionsSheet`. ✓ no gaps.

**Placeholder scan:** none — every step has full code or an exact command.

**Type/name consistency:** `subMonthID`/`subYearID` (B1) referenced identically in B2 (`store.subMonth/subYear`) and B3 (`StoreManager.subMonthID/subYearID`). `purchaseSubscription(_:)` (B1) called in B2. `.quotaExceeded(used:limit:)` (B4) caught in B5. `.quotaWall(used:limit:)` (B5 VM) matched in B5 view. `QuotaErrorBody`/`ErrorResponse` decode the backend's `{error,used,limit}` (A1 response shape). `reloadQuota` defined + used in B3. ✓ consistent.
