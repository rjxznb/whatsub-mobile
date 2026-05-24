# iOS Monetization — Next Steps / Handoff (2026-05-24)

> **For a new session:** This is the current state + what's left of the iOS-monetization work. Read this first, then `docs/superpowers/specs/2026-05-24-ios-monetization-design.md` for the full design. The `feedback-monetization-oss-quota` memory has the running decision log.

## Where things stand (all DEPLOYED / SHIPPED 2026-05-24)

**Model (3 independent entitlements):** 网站 license (one-time) / iOS 买断 ¥18 (one-time IAP) / iOS 订阅 ¥12月·¥88年 (recurring IAP, for the 50-quota).
- App unlock = `hasActiveLicense || iosBuyout || iosSubActive || trial-active`. Phone: 1-day free trial → hard paywall → ¥18 buyout unlocks app + public corpus.
- Storage quota (50 vs 3) → **subscription** (Phase 3); currently still license-gated.

**Product IDs (App Store Connect, created):**
- Buyout (Non-Consumable): `cc.eversay.whatsub.mobile.fullunlock` — ¥18
- Subscription group **whatSub pro** (ID `22110396`): `whatsub_pro_month` ¥12 / `whatsub_pro_year` ¥88
- App's numeric Apple ID: **6771697837**

**Backend (whatsub-license `main`, deployed to prod env=Sandbox):**
- `ios_entitlements` table (email-keyed) + `Database` methods (`ensureTrialStarted`, `getIosEntitlements`, `grantBuyout`, `revokeBuyout`, `setSubscription`, `extendSubscription`, `expireSubscription`).
- `src/lib/appleVerifier.ts` — `@apple/app-store-server-library` `SignedDataVerifier`, built from env, injected into `iapRoute`.
- `POST /api/iap/verify` (session) + `POST /api/iap/notifications` (ASSN V2). Public URLs: `https://whatsub.eversay.cc/api/license/iap/{verify,notifications}` (the existing `/api/license/` nginx rule proxies them — no nginx change).
- `GET /api/auth/me` returns `{iosBuyout, iosSubActive, subProductId, trialExpiresAt}` + starts the trial.
- `routes/library.ts` `quotaLimit` is **STILL `hasActiveLicense ? 50 : 3`** (Phase-3 flip pending).
- Verified live: logs `[iap] Apple verifier enabled (env=Sandbox)`; `POST /iap/notifications {}` → 400 (not 503).

**iOS (whatsub-mobile `main`, TestFlight build #147):**
- `Store/StoreManager.swift` (StoreKit 2: load buyout product, purchase, restore, `Transaction.updates` listener, offline `hasLocalBuyout`, reports JWS to `/iap/verify`).
- `Paywall/PaywallView.swift` (full-screen ¥18 buyout + 恢复购买 + 隐私/Apple-EULA links; NO external purchase link).
- `ContentView` gate: splash → paywall → tabs; `appUnlocked` **fails open** when `trialExpiresAt` is nil.
- `MeResponse` extended; MeView purchase row is plain text (anti-steering).

**Website:** `whatsub.eversay.cc/privacy` updated for iOS data + deployed.

## Gotchas already solved (don't re-trip)
- **Compose uses an explicit `environment:` block** (not `env_file` passthrough) → new env vars must be added to BOTH `docker-compose.yml` AND `/opt/whatsub/.env`.
- **Dockerfile must copy `src/lib/apple-root-certs/`** into the runtime image (tsc only emits `.ts`→`dist/`). Done.
- **Share-extension `CFBundleVersion`** must declare `$(CURRENT_PROJECT_VERSION)` in project.yml or XcodeGen defaults it to `"1"` → App Store validation error. Fixed.
- **Sandbox vs Production**: backend env=`Sandbox` now (TestFlight IAP is sandbox). ASSN sandbox notifications go to the **Sandbox** webhook URL.
- **Deploy is build-locally→ship-image** (server can't build). SSH `root@47.93.87.206` key `~/.ssh/id_ed25519`; license at `/opt/whatsub/`, postgres=`enghub-postgres-1`, nginx=`enghub-nginx-1`. Full runbook in whatsub-license `CLAUDE.md` "Build + deploy".

---

## A. Immediate — finish testing (mostly the user)
- [ ] **User: set the ASC Sandbox webhook URL** = `https://whatsub.eversay.cc/api/license/iap/notifications` (Production URL already set; Sandbox was empty). App Store Connect → App → App 信息 → App Store 服务器通知 → 沙盒环境服务器 URL.
- [ ] **User: sandbox test build #147** — install, log in (24h trial → app works). To see the wall now: `docker exec -i enghub-postgres-1 psql -U whatsub_license_user -d whatsub_license -c "UPDATE ios_entitlements SET trial_started_at=0 WHERE email='<your-email>';"` → relaunch → paywall → buy ¥18 with a **Sandbox Apple ID** → unlocks. Test 「恢复购买」 (reinstall → restore).
- [ ] Confirm `/api/iap/verify` records the buyout (check `ios_entitlements` row gets `buyout_at`). If OCSP egress to `ocsp.apple.com` from the Beijing box fails verification, set `enableOnlineChecks=false` in `createAppleVerifier` (whatsub-license `src/lib/appleVerifier.ts`) + redeploy.

## B. Phase 3 — iOS subscription (¥12月/¥88年) + flip storage quota to subscription
Goal: the 50 cloud-video quota becomes subscription-gated; license alone no longer grants 50. Build the subscription purchase UI (only shown to license holders, since only a desktop can fill OSS).

**B1 — Backend (whatsub-license):** flip `routes/library.ts` `quotaLimit` from `c.get('hasActiveLicense') ? 50 : 3` to use `iosSubActive`. Source `iosSubActive` from the session's entitlements (add it to the context in `requireSession` via `getIosEntitlements`, or look it up in the quota path). Update `library-quota` tests. **Ship this together with B2** (flipping alone would drop current license users to 3 with no way to get 50 until the iOS subscription UI exists).

**B2 — iOS subscription UI (whatsub-mobile):**
- Extend `StoreManager` to also load `whatsub_pro_month` + `whatsub_pro_year` (`Product.products(for:)`), add `purchaseSubscription(_ product:)` (same verify→`/iap/verify`→refreshMe path; `/verify` already handles `kind:'subscription'`).
- In `MeView`, **only when `appState.currentUser?.hasActiveLicense == true`**, show a subscription section: current quota (`used/limit` via `GET /api/license/library/quota`), month/year options + 「升级到 50」 purchase + 恢复购买 + the system 「管理订阅」 link. Non-license / buyout-only users: keep the text-only quota card (they can't fill OSS, so don't sell them storage).
- The existing 「云端同步」 card (#145) becomes this section.

**B3 — Integration:** push iOS to TestFlight (user-authorized), redeploy backend with the quota flip, sandbox-test a subscription purchase → quota becomes 50.

Write a proper plan (superpowers:writing-plans) before executing B; backend is locally testable (pg-mem), iOS is CI-built.

## C. Public App Store release (before going live)
- [ ] Switch backend `APPLE_ENVIRONMENT=Production` (in `/opt/whatsub/.env` + redeploy) and ensure the **Production** ASSN webhook URL is set (it is).
- [ ] Reviewer notes + a **pre-expired demo account** (set its `trial_started_at=0`) so the reviewer can reach the paywall + test IAP in sandbox (the 1-day hard wall otherwise hides the paywall on day 1 — known review risk the user accepted).
- [ ] Small Business Program (applied ✅). Privacy policy URL set in ASC App Information = `https://whatsub.eversay.cc/privacy`.
- [ ] Submit for App Review. If rejected for "1-day hard paywall / insufficient free value", fall back to "free 看内嵌+字幕, 高级功能买断" or lengthen the trial (the gate code already centralizes this).

## Key file pointers
- Spec: `docs/superpowers/specs/2026-05-24-ios-monetization-design.md`
- Phase 1 plan: `docs/superpowers/plans/2026-05-24-ios-monetization-phase1-backend.md`
- Phase 2A plan: `docs/superpowers/plans/2026-05-24-ios-monetization-phase2a-backend-verifier.md`
- iOS gate: `whatsub-mobile/App/WhatsubMobileApp.swift` (ContentView) + `Networking/DTOs.swift` (`MeResponse.appUnlocked`)
- Backend verifier: `whatsub-license/src/lib/appleVerifier.ts` + `src/routes/iap.ts` + `src/lib/db.ts` (ios_entitlements methods)
