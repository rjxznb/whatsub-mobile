# whatsub-mobile — Architecture

iOS consumer client for whatSub. SwiftUI native, iOS 16+. Reads public/private corpus + cloud-synced library subtitles from the [whatsub-license](https://github.com/rjxznb/whatsub-license) backend. Companion to the [desktop Tauri app](https://github.com/rjxznb/whatsub-releases) (private repo for source) which produces the data this app consumes.

**Status**: v1 + post-v1 features on TestFlight (2026-05-22/23). Phase 1 (scaffold + CI + TestFlight) ✅; Phase 2a (email-OTP auth) ✅; Phase 2c (Library list + bilingual subtitle reader) ✅; Phase 2b (语料库 browse + phrase detail) ✅. Backend thumbnail sync ✅. **Self-hosted video** ✅: native AVPlayer from Aliyun OSS+CDN (no VPN, instant seek), landscape→fullscreen, on-video bilingual captions + CC toggle, player loading overlay + VPN hint; fallback to YouTube embed. **Swipe-to-delete** ✅: left-swipe a Library card → confirm → removes from cloud (backend row + OSS object). **Share-to-import** ✅: in-app YouTube import (WKWebView+fetchHook caption intercept, bypassing po_token) + LLM analysis (user's openai-compatible key, client-side) → preview → sync; Share Extension (YouTube/Safari → whatSub via App Group + `whatsub://` deep link); push caption-less videos to desktop import queue. **Library VPN badge** ✅: 免VPN (OSS-hosted) vs 需VPN badge per card; imported videos upload their cover thumbnail. **Generic URL import** ✅: any non-YouTube URL (Bilibili first) auto-routes to the desktop import queue (desktop yt-dlp + whisper transcribes the English audio → OSS self-hosted → plays 免VPN); `VideoSource` classifies the URL (YouTube keeps the client-side caption path), and playback guards against ever embedding a non-YouTube id (shows a "在桌面端查看" placeholder when no OSS video); the 我的 tab has a 「导入队列」 view surfacing each push's status + failure reason with a 重试 (re-enqueue → reset to pending) button. **单词卡测验** ✅: 语料库 tab → a flashcard multiple-choice quiz (英→中, 4 options, wrong→✗+retry, correct→inline reveal) over the 公共/个人 corpus phrases, with persistent local progress (`Documents/quiz_progress.json`, mastery threshold + weighted selection), IPA phonetics under each prompt (bundled offline en-US dict `Resources/ipa-en-us.json`, reused from the desktop, per-word lookup) + a correct-answer system sound + success haptic; client-side only, no backend change. **语料库持久化缓存** ✅: corpus list + tapped phrase lookups cached to `Caches/corpus_cache.json`, invalidated by `GET /api/corpus/versions` (`{mine,public}`) + 24h TTL + 500-entry LRU on lookups — cache-first (instant + offline), no per-tap server calls; no backend change. **Library 同步额度 + per-video cap** ✅ (2026-05-28): three-tier fence — free 3 视频 × 100MB × 20min / sub 50 视频 × 500MB × 60min。后端 `/upload-url` early-fail 413 + `/sync` HEAD-backstop (OSS object size 真实校验，恶意客户端伪造 contentLength 也会被拒+清理) + 客户端 pre-check (duration before transcode 省 ffmpeg CPU、size after) + 友好中文错误 dialog (`video_too_large` / `video_too_long`) with Pro upsell deep-linking to `https://whatsub.eversay.cc/mobile#pro`；`/me.libraryLimits` + `/quota.limits` 为客户端统一来源。 **iOS 收费 — 单一订阅模式 (policy shift 2026-05-28)** ✅: 退役 ¥18 一次性买断（`cc.eversay.whatsub.mobile.fullunlock` SKU 在 App Store Connect 完全删除——无任何真实购买记录、不需要 grandfathering）；移除 1 天试用门 + 全屏硬付费墙；app 安装即用，**只有「免费版」「已订阅 Pro」两种状态**。Pro = `whatsub_pro_month` ¥12/月 OR `whatsub_pro_year` ¥88/年；解锁公共语料库 + 50 视频 × 500MB × 60min + 1000 个人语料。CorpusView 公共 tab 403 → 上下文 SubscribeSheet（不再是硬付费墙）；ImportView 配额墙 → SubscriptionOptionsView 内购；StoreKit 2 `Transaction.updates` 监听 + `POST /api/license/iap/verify` 上报 JWS。后端 `hasCorpusAccess = license OR iosBuyout(grandfathered, 无实际用户) OR hasActiveSubscription`，修复了之前只查 `iosSubActive` 漏掉 Alipay 时段会员的 bug。`PaywallView.swift` 已删除 (dead code)；StoreManager 移除 `buyoutProductID/Product/hasLocalBuyout/purchaseBuyout`；DTOs 移除 `iosBuyout` + `trialExpiresAt` + `appUnlocked`。** Three tabs: Library / 语料库 / 我的. **Video player fix (2026-05-25/26):** `AVPlayer` 提升到 `LibraryDetailView` `@State(avPlayer)` 并传入 `VideoPlayerView`（后者不再自建），解决横竖屏切换重启播放问题；字幕渲染到 `AVPlayerViewController.contentOverlayView`（UIKit），在原生全屏（含 iPad）也能显示。**Other fixes:** 订阅按钮在 List 行中同时触发 → `.buttonStyle(.borderless)`；Library 空态 iPad 居中；退出登录确认对话框；YouTube 真实标题 via oEmbed。**授权状态 + 语料配额服务端权威 (TestFlight #154, 2026-05-26)** ✅：`MeView` 授权状态行显示解锁来源（**网站授权 · 有效 / 已订阅 Pro / 免费版**，3 种状态；2026-05-28 政策变更后试用 + 买断已从产品里移除）；`CorpusView` 个人语料配额改读 `GET /api/corpus/quota`（服务端权威 `limit = hasActiveSubscription?1000:50`，正确反映支付宝/网页订阅；best-effort，失败回退本地计数 + `iosSubActive` 猜测）—— 后端同时新增该端点（`974be3f`，已部署 prod），与既有 `GET /api/library/quota` 对称。**网站 Pro 订阅入口** ✅: `whatsub.eversay.cc/mobile#pro` 上 Alipay 月/年订阅卡（`whatsub-website/src/components/ProSubscriptionCard.tsx`，2026-05-28），桌面 Get_Video 配额对话框 deep-link 到此；iOS 客户端默认走 Apple IAP（不能从 app 跳网站，App Store 反对引导）。**Next: App Store 公开上架**（env=Production + 演示账号 `appreview@eversay.cc` / `424242` 已就位 + iOS 6894c9f 含零买断/试用残留，即将提审）。

## Stack

- **Swift 5.10 + SwiftUI** · iOS 16+ · Xcode 16+
- **XcodeGen 2.43+** generates `.xcodeproj` from `project.yml` (never edit pbxproj directly; `.gitignore`'d)
- **GitHub Actions (`macos-15`)** for CI + TestFlight upload
- **No third-party Swift deps** (URLSession, WKWebView, Keychain Services — all native). Dev only: SwiftLint planned for Phase 2.
- **App Store Connect API key** (`.p8`) for fully-automated signing; no manual cert/profile management

## Repos this app talks to

| Repo | Role | URL |
|---|---|---|
| `whatsub-license` | Backend Hono+Postgres, owns `/api/auth/*`, `/api/corpus/*`, `/api/library/*` | https://github.com/rjxznb/whatsub-license |
| `whatsub-releases` | Desktop Tauri app source (private mirror at `rjxznb/whatsub`) — produces the library data we sync | — |
| `whatsub-website` | Marketing static site at `https://whatsub.eversay.cc` | https://github.com/rjxznb/whatsub-website |

## Layout

```
whatsub-mobile/
├── project.yml              # XcodeGen spec — single source of truth for .xcodeproj
├── ExportOptions.plist      # xcodebuild exportArchive config (method=app-store)
├── whatsub-mobile/          # Swift source target (note: same name as repo root)
│   ├── App/                 # @main + AppState + Theme
│   ├── Views/               # SwiftUI placeholder views (Phase 1) / real views (Phase 2)
│   ├── Assets.xcassets/     # AppIcon + AccentColor
│   ├── Info.plist
│   └── PrivacyInfo.xcprivacy
├── .github/workflows/
│   ├── ci.yml               # every push: simulator build + screenshot artifact
│   └── testflight.yml       # main push: archive + sign + upload TestFlight
└── docs/superpowers/        # spec + plans for v1 (see README.md "Phase" rollout)
```

## Apple Developer config (already established)

- Team ID: `Q3BK52FQT9`
- Bundle ID: `cc.eversay.whatsub.mobile`
- App Store Connect record: `whatSub`
- API Key Name: `GitHub Actions` (App Manager access)
- Internal Tester: `2216681472@qq.com` (in Internal Group `whatsub`)

## Build / dev

```bash
# Local (Mac with Xcode):
brew install xcodegen
xcodegen generate
open whatsub-mobile.xcodeproj

# CI does this automatically on every push.
# Without Mac access: edit .swift / project.yml / .github/workflows on Windows,
# push to GitHub, watch CI artifacts (screenshots) for visual feedback.
```

## CI / TestFlight

Two workflows in `.github/workflows/`:
- `ci.yml` — every push: build for `iPhone 15 Pro` simulator, screenshot launch tab, upload artifact. ~3 min.
- `testflight.yml` — main push: archive + export IPA + `xcrun altool --upload-app`. ~10 min when secrets present.

### One-time secrets (in GitHub repo Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Full content of `AuthKey_<KEY_ID>.p8` including PEM headers |
| `APP_STORE_CONNECT_KEY_ID` | 10-char key ID (filename without prefix/extension) |
| `APP_STORE_CONNECT_ISSUER_ID` | UUID from App Store Connect Integrations page |

The `.p8` file should be deleted from local disk after upload to GitHub Secrets — never commit, never share. `.gitignore` already excludes `AuthKey_*.p8` as a belt-and-suspenders.

## Key design decisions

- **XcodeGen, not Tuist**: Tuist is more powerful but uses a Swift DSL that requires macOS to author. XcodeGen YAML is fully editable from Windows. Single-target v1 doesn't need Tuist's power.
- **Automatic signing + ASC API key**: `xcodebuild -allowProvisioningUpdates -authenticationKey* …` lets the runner fetch a fresh distribution cert + provisioning profile from Apple on every CI run. **No local cert/profile management ever.** The cost: every Archive talks to Apple's API; if Apple is down or the key is revoked, CI fails.
- **TestFlight Internal Testing only for v1**: skips Apple Beta App Review. Limit 100 internal testers; the only one for v1 is the owner.
- **Chinese-only UI hardcoded**: matches the desktop app. No i18n tables for v1. `developmentLanguage: zh-Hans` in project.yml + `CFBundleDevelopmentRegion = zh-Hans` in Info.plist.
- **iOS 16 minimum**: gives us NavigationStack + AsyncImage + the `.foregroundStyle` API; covers ~94% of devices in 2026.
- **0 third-party Swift packages**: every line of code is auditable + builds are reproducible without dependency resolution. Trade-off: more boilerplate (URLSession wrapper, Keychain helper). Acceptable for v1's scope.

## Post-v1 features shipped (2026-05-22/23)

### Self-hosted video (OSS + CDN + AVPlayer)

Library detail plays synced videos via native `AVPlayerViewController` (`Components/VideoPlayerView.swift`) when the backend returns a `videoUrl` (signed Aliyun CDN URL, 2h TTL). Falls back to `YouTubeEmbedView` when `videoUrl` is null.

- Landscape orientation → fullscreen AVPlayer (standard iOS behavior via AVPlayerViewController).
- On-video bilingual captions: `SubtitleOverlayView` composited over the player; CC toggle hides/shows.
- Loading overlay with spinner + "正在连接…" until AVPlayer fires `.readyToPlay`; 15s timeout shows VPN hint (AVPlayer path: no VPN hint needed since OSS is China-reachable; YouTube embed path: shows VPN hint on timeout).
- `LibraryEntryDetail.videoUrl` added to `DTOs.swift`.

### Swipe-to-delete

`LibraryView.swift` — `.swipeActions(edge: .trailing)` on each row → `pendingDelete` state → `.confirmationDialog("从云端删除…?")`. Confirm calls `vm.delete(id, token:)` → `WhatsubAPI.deleteLibraryEntry` → `DELETE /api/library/sync/:id` (backend also removes OSS object) → removes entry from local list. Desktop reconciles the stale ✓ badge on next Library mount.

### Share-to-import (Phase 0-2)

**In-app import flow** (`Import/` views): a URL field in the 我的 tab → `YouTubeCaptionExtractor` (hidden WKWebView + injected `fetchHook.js` + `WKScriptMessageHandler`) → `parseTimedtextJson3` (json3 → `[Cue]`) → `LLMAnalyzer` (user's openai-compatible key from Keychain; chunks cues → `/chat/completions` → `AnalysisJson`) → `ImportFlowView` preview (reuses bilingual cue renderer) → "同步到云库" → `WhatsubAPI.syncLibraryEntry` → `POST /api/library/sync`.

**LLM Settings** added to 我的 tab: provider=openai-compatible, `baseUrl`/`apiKey`/`model` (default DeepSeek), stored in Keychain.

**Share Extension** (`whatsub-share/` target): `ShareViewController.swift` (UIViewController extension principal class) — extracts URL from `NSExtensionItem` (`public.url` / `public.text` fallback) → writes to `AppGroup.pendingImportURL()` → `extensionContext?.open("whatsub://import?url=…")` + responder-chain fallback. Main app `WhatsubMobileApp.swift`: `.onOpenURL` → read AppGroup → set `pendingImportURL` state → present `ImportView` prefilled + auto-run.

**Push to desktop import queue** (`推送到桌面`): on caption-extraction failure, `ImportViewModel` offers `pushToDesktop(token:)` → `WhatsubAPI.enqueueImport(url:, token:)` → `POST /api/library/import-queue`. The desktop poll loop picks it up and runs its full pipeline (yt-dlp + whisper + LLM + cloud sync).

### Library VPN badge + imported cover upload

Each Library card shows a badge: "免VPN" (blue, when `videoUrl` is non-nil = OSS-hosted = no VPN needed) or "需VPN" (gray, YouTube embed only). Imported videos (no desktop thumb) upload a thumbnail by fetching `i.ytimg.com/vi/{id}/mqdefault.jpg` and sending it as `thumbData` in the sync payload — so the Library card shows a cover without VPN on subsequent loads.

### Login rate-limit awareness (2026-06-02, build 231)

The backend's `/api/license/auth/{send-code,verify-code}` is rate-limited (policy: `whatsub-license/src/lib/authRateLimit.ts` — 2/min + 20/h per email + 30/h per IP for send-code; 15/h aggregate attempts per email + 30/h per IP for verify-code). The iOS client cooperates on three layers:

1. **Wire**: `APIError.rateLimited(scope, retryAfterSec, message)` parses the 429 body (`{error, scope, retryAfterSec, message}`) AND falls back to the `Retry-After` header. See `WhatsubAPI.send()` 429 branch + `RateLimitErrorBody` in `DTOs.swift`.
2. **VM state**: `AuthViewModel.sendBlockedUntil: Date?` is set on both successful sends (local 30s soft cooldown — strictly shorter than the server's 60s/2 window so users never trip the real 429 in normal use) and 429 responses (server-driven retryAfterSec). `sendRetrySeconds(at:)` is read by the view inside a `TimelineView` so the countdown ticks every second without a separate Timer.
3. **UI**: `AuthGateView` shows "请等待 N 秒" on the send button + dims its accent color while blocked. The code-step view also shows "· N 秒后可重发" next to the back-to-email link, transitioning to a "重新发送" button when the cooldown elapses.

If the server policy changes, edit `whatsub-license/src/lib/authRateLimit.ts` only — the client respects whatever `retryAfterSec` the server sends.

## 踩过的坑 (avoid repeating)

### CI / GitHub Actions / iOS toolchain

- **GitHub Actions billing block on private repo can stop all workflows pre-start.** Error message: "recent account payments have failed or your spending limit needs to be increased". This blocks even Linux runs, not just expensive macOS ones. For solo dev hobby projects: simplest fix is `gh repo edit <repo> --visibility public --accept-visibility-change-consequences` — public repos get unlimited free Actions minutes (including macOS). The repo's secrets stay encrypted regardless of visibility. Trade-off: code is world-readable. For consumer apps where the value is in the iOS experience + cloud backend (not the client code itself), public is usually fine.

- **XcodeGen 2.43+ emits `objectVersion 77` pbxproj which only Xcode 16+ can read.** Symptom in CI: `xcodebuild: error: The project 'X' cannot be opened because it is in a future Xcode project file format (77). Adjust the project format using a compatible version of Xcode...`. Fix: `runs-on: macos-15` (Xcode 16.x default), NOT `macos-14` (Xcode 15.4 default). Both have the same 10x-weight cost on private repos; both are free on public.

- **`xcodebuild` `-authenticationKeyPath` requires `-authenticationKeyID` AND `-authenticationKeyIssuerID` non-empty.** Symptom: `xcodebuild: error: The flag -authenticationKeyID is required when specifying -authenticationKeyPath` even though the flag IS in the command. Real cause: the SECRET env var was empty (not the flag). Happens when GitHub Secrets aren't set yet but the workflow runs anyway. Defensive fix: add a `Verify secrets present` step early in the testflight workflow that errors with a clear message if any of the 3 ASC secrets is unset. (Not in CI today; add when the missing-secret pattern bites a second time.)

- **`printf '%s' "$EMPTY_VAR" > file.p8` succeeds silently** — produces an empty file. Then downstream xcodebuild fails with the cryptic flag error above. The earlier step shows green in CI, masking the real cause. Always sanity-check secret content in CI: `wc -c file.p8` should be > 200 for a valid .p8.

- **App Store Connect API key with "App Manager" role can NOT create Distribution certs.** Symptom in CI: `xcodebuild archive` with `-allowProvisioningUpdates` + ASC API key fails with `Communication with Apple failed: Your team has no devices from which to generate a provisioning profile`. The error is misleading — it sounds like a Development profile issue, but the real cause is that App Manager role lacks the permission to create the Distribution cert that Archive needs. Apple's API silently downgrades to attempting Development profile creation, which then fails on missing devices. **Fix: create a new API key with Admin role** (Connect → Users and Access → Integrations → Keys → "+" with Access: Admin). API key roles cannot be changed in-place — must revoke old + create new + re-upload `.p8` to GitHub Secrets. Trying any of these workarounds is futile until the key role is upgraded: forcing `CODE_SIGN_IDENTITY="Apple Distribution"` (conflicts with Automatic mode), per-config CODE_SIGN_IDENTITY in project.yml (also conflicts), passing `CODE_SIGN_STYLE=Manual` (then needs pre-created profile).

- **`CODE_SIGN_STYLE=Automatic` + forced `CODE_SIGN_IDENTITY` = conflict error.** Symptom: `whatsub-mobile is automatically signed for development, but a conflicting code signing identity Apple Distribution has been manually specified.` When using Automatic signing, do NOT manually set CODE_SIGN_IDENTITY anywhere (project.yml, xcodebuild CLI, .xcconfig). Let Automatic mode pick — for Release configs with `-allowProvisioningUpdates`, it requests Distribution from Apple. (Note: this only works if the API key has Admin role per the previous gotcha.)

- **A team with zero registered devices fails even Distribution provisioning** with the misleading error `Communication with Apple failed: Your team has no devices from which to generate a provisioning profile.` Apple's automatic signing has an initialization door — without ≥1 device in `Developer Portal → Devices`, signing flows can't proceed even for App Store Distribution (which logically shouldn't need devices). Fix: add at least 1 iPhone UDID to the team. UDID via Finder (Mac) when iPhone is connected → click serial number to cycle to UDID; or via `get.udid.io` from Safari on the iPhone itself. One-time setup; no ongoing maintenance.

- **App Store rejects large app icons with alpha channel.** Symptom on `xcrun altool --upload-app`: `Validation failed (409) Invalid large app icon. The large app icon in the asset catalog in "X.app" can't be transparent or contain an alpha channel.` The 1024×1024 PNG in AppIcon.appiconset must be RGB (no alpha). If the source PNG is from a desktop app icon set (often RGBA for transparent backgrounds), strip alpha before commit. PowerShell one-liner that fills transparency with brand black: `Add-Type -AssemblyName System.Drawing; $s=[Drawing.Image]::FromFile('icon.png'); $d=New-Object Drawing.Bitmap($s.Width,$s.Height,'Format24bppRgb'); $g=[Drawing.Graphics]::FromImage($d); $g.Clear([Drawing.Color]::Black); $g.DrawImage($s,0,0); $d.Save('icon.png','Png'); $s.Dispose(); $g.Dispose(); $d.Dispose()`. Verify resulting pixel format = `Format24bppRgb` (not `Format32bppArgb`).

- **Cloud signing mints a NEW Apple Distribution cert per Archive — Apple caps at ~2-3, so frequent CI eventually fails with "maximum number of certificates".** Symptom on `xcodebuild archive`: `error: Choose a certificate to revoke. Your account has reached the maximum number of certificates. To create a new one, you must choose a certificate to revoke.` + `No profiles for 'cc.eversay.whatsub.mobile' were found`. Root cause: `-allowProvisioningUpdates` + ASC API key requests a fresh Distribution cert whenever it can't reuse one; after many TestFlight runs (hit it after ~8 in one day) the account's Distribution-cert slots fill up. The build itself is fine — only the Archive/sign step fails, and code already merged to main. **Fix (manual, ~2 min, one-time until it refills):** developer.apple.com → Certificates, Identifiers & Profiles → Certificates → revoke the older "Apple Distribution" certs (keep at most one; CI mints a fresh one next run). Then re-run WITHOUT a new commit: `gh run rerun <run-id> --repo rjxznb/whatsub-mobile`. Long-term mitigation (deferred): export one Distribution cert+key to a GitHub Secret and use manual signing instead of cloud-minting a new cert each run — but that reintroduces the cert/profile management this project deliberately avoided.

- **Apple requires iOS 26 SDK (Xcode 26+) for any TestFlight or App Store upload as of 2026.** Symptom on `altool --upload-app`: `Validation failed (409) SDK version issue. This app was built with the iOS 18.5 SDK. All iOS and iPadOS apps must be built with the iOS 26 SDK or later, included in Xcode 26 or later`. `macos-15` GitHub runner ships several Xcode versions side-by-side; the default xcodebuild may still point at Xcode 16. Fix: add `maxim-lobanov/setup-xcode@v1` with `xcode-version: latest-stable` as an early step in both ci.yml and testflight.yml to switch the runner's active Xcode to the newest installed. Verify in the build log via `xcodebuild -version` — should print Xcode 26.x.

### Swift / SwiftUI

- **`.foregroundStyle(.whatsubAccent)` needs the static defined on `ShapeStyle`, not just `Color`.** Symptom: `type 'ShapeStyle' has no member 'whatsubAccent'`. The leading-dot shorthand resolves member lookup against the parameter type (`ShapeStyle`), not the value type (`Color`). Defining `extension Color { static let whatsubAccent = ... }` compiles for `Color.whatsubAccent` but not the `.whatsubAccent` shorthand inside `.foregroundStyle()`. Always pair Color statics with a `ShapeStyle where Self == Color` extension — see `whatsub-mobile/App/Theme.swift` for the template. Built-in SwiftUI does this for `.red` / `.blue` / etc.

- **`.foregroundStyle(.secondary)` works without our help** — `.secondary` is already a `ShapeStyle` static (`HierarchicalShapeStyle.secondary`). The trap is custom colors.

- **Swift bare `catch {}` binds an implicit immutable constant named `error`** — which shadows any property/var named `error`, making `error = ...` fail with "cannot assign to value: 'error' is immutable". Don't name a `@Published` property `error`; use `errorMessage`. (Hit in AuthViewModel.)

- **System large nav title is flaky with a custom global `UINavigationBarAppearance` + custom full-bleed background + push/pop.** Symptom: the `.navigationTitle("Library")` large title intermittently (a) collapses ~1s after popping back from a pushed detail (nav bar disappears, list slides up), or (b) reserves space but renders no visible text. Multiple structural attempts (background as `.background` modifier vs ZStack sibling; navigationDestination at root vs in a conditional branch; `.toolbarBackground`) did NOT reliably fix it. The robust fix: **drop the system large title and render a custom `Text("Library")` header** inside the content + `.toolbar(.hidden, for: .navigationBar)` on the root screen (the pushed detail view still shows its own bar + back button). See `Library/LibraryView.swift`. Trade-off: lose the large-title shrink-on-scroll animation, but gain 100% reliable rendering + exact brand styling.

- **LLM/pipeline JSON is not schema-clean — decode external blobs leniently.** Prod `analysisJson.subtitles[].keyNotes` is declared `[String: String]` but the desktop pipeline occasionally merges a nested `highlightTranslations` object in as a value, so a strict `[String: String]` decode throws and fails the ENTIRE entry → user sees "数据格式不正确". Fix: decode such maps with a tolerant helper (`DynamicKey` keyed container, keep only string values, drop the rest) — see `Cue.lenientStringMap` in `Networking/DTOs.swift`. General rule: anything an LLM produced gets defensive parsing at the boundary; never let one malformed field nuke a whole response.

- **`AVPlayerViewController.transportBarCustomMenuItems` is tvOS-only — unavailable on iOS.** Attempted to add a fullscreen CC toggle there; breaks Archive with `'transportBarCustomMenuItems' is unavailable in iOS`. iOS `AVPlayerViewController` has no clean custom-control-bar API. The only in-fullscreen custom control option is a hit-test-passthrough button in `contentOverlayView` (deferred). Do not attempt this API on the iOS target.

- **Multiple default-style `Button`s in one SwiftUI `List` row all fire on a single row tap.** Symptom: tapping anywhere on a subscription row triggers every button in that row at once. Fix: `.buttonStyle(.borderless)` on each `Button` inside the `List` row — borderless buttons capture only their own touch area.

- **SwiftUI's automatic keyboard avoidance is FLAKY in NavigationStack + `Color.ignoresSafeArea()` + `.safeAreaInset(edge: .bottom)` + `TextField(axis: .vertical)`.** Symptom we cycled through builds 216-231: sometimes the keyboard hides the input box, sometimes it works, sometimes hovering above the keyboard with a 100pt gap (double-pad: system auto + our manual). Root cause is that the four modifiers interact through SwiftUI's safe-area system, and any state churn (`@Published` updates, sheet presentations, `.task` recreation) can leave auto-avoidance silently off without firing again. **Don't mix.** Pick one source of truth: opt out of auto avoidance with `.ignoresSafeArea(.keyboard, edges: .bottom)` on the container, then drive `.padding(.bottom, keyboardOffset)` on the inset content from `UIResponder.keyboardWill{Show,Hide}Notification`. Template lives in `QuickChatView.swift`'s body — copy that pattern when you need a keyboard-aware bottom bar.

- **Dragdown-to-dismiss keyboard guarded on `@FocusState` can fall silent — `@FocusState` desyncs from the actual keyboard state.** Symptom: swipe-down does nothing while the keyboard is clearly up. Cause: the TextField loses focus due to a state transition (re-render, sheet appearing, etc.) but the IME stays mapped to the same first responder, so the keyboard hangs around while `typingFieldFocused == false`. Fix: don't gate on `@FocusState` — dismiss unconditionally on the gesture via `UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)`. It's a no-op when nothing has focus, so there's no harm.

### Share-to-import + Share Extension

- **YouTube timedtext requires a `po_token` (anti-scrape, 2024) that cannot be forged client-side.** URLSession `GET /api/timedtext` always returns 403. The only working path: **inject a MAIN-world fetch hook (`fetchHook.js`) into a WKWebView that loads the real YouTube player** — the player fetches timedtext with its own already-signed request; the hook intercepts the response body and posts it to the app via `WKScriptMessageHandler("whatsub-yt-fetch-hook")`. This is exactly what the browser plugin does. There is NO clean URLSession path. The hidden WKWebView + hook approach is also why import flow is slower than a direct API call (~10-30s for the player to load + CC to trigger).

- **Share Extension is a separate target + separate bundle ID + App Group.** The extension (`cc.eversay.whatsub.mobile.share`) and the main app (`cc.eversay.whatsub.mobile`) share the `group.cc.eversay.whatsub.mobile` App Group entitlement. Both targets must have this entitlement, both must be registered in the Apple Developer portal (App Groups capability), and the provisioning profiles for BOTH must include the capability — otherwise the extension silently fails to read/write the shared UserDefaults. `AppGroup.swift` is compiled into both targets (listed in `project.yml` under both `sources`).

- **iOS doesn't reliably auto-launch the host app from a Share Extension.** `extensionContext?.open(url)` works in theory but is blocked on some iOS versions when the app is not in the foreground. The robust pattern used here: call `extensionContext?.open(url, completionHandler:nil)` AND also try `self.view.window?.rootViewController?.open(url)` via the responder chain. The main app also has a `scenePhase`-based safety net: on `active` it reads `AppGroup.pendingImportURL()` and opens ImportView if a URL is waiting — this catches the case where the user was already in the app or navigated back before the deep link fired.

### Networking / China reachability

- **`i.ytimg.com` (YouTube thumbnail CDN) is GFW-blocked in mainland China** — `curl` without VPN times out (HTTP 000); with VPN it's 200. The iOS Library list uses `https://i.ytimg.com/vi/{id}/mqdefault.jpg` for covers, so without a VPN the thumbnails don't load (AsyncImage shows the placeholder). The YouTube player embed (youtube-nocookie.com) has the SAME constraint, so the feature already requires VPN to actually watch. Note: the DESKTOP app avoids this entirely by using locally-extracted thumbnails (ffmpeg frame grab → thumb.jpg), NOT Google's CDN. If the Library list must be browsable WITHOUT VPN, the proper fix is to sync the desktop's local thumb.jpg to our own backend (whatsub.eversay.cc, China-reachable) and serve it from there — a Plan 3 + backend + storage change, deferred. For now AsyncImage falls back to a play-icon placeholder.

### Local dev on Windows

- **`localhost:3030` curl hits `http_proxy` instead of the loopback** when the user has a VPN/proxy env set (e.g. Clash on 127.0.0.1:7890). Symptom: `HTTP 502 Bad Gateway` with proxy headers in response. Fix: `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY` in the same shell before curl, OR `curl --noproxy '*'`. Backend itself is fine; this is purely a client-side proxy interference.

- **Git on Windows nags about LF → CRLF on every `git add` of text files.** Cosmetic — git stores LF in the blob regardless. To silence: create `.gitattributes` with `* text=auto eol=lf` at repo root. Not done in v1 because the warnings are scrollable noise, not actually breaking anything.

- **`taskkill /F /PID <n>` from Git Bash fails with "无效参数 - 'F:/'"** because Git Bash's MSYS path translation thinks `/F` is a Unix path. Fix: use PowerShell tool with `Stop-Process -Id <n> -Force`, or escape: `taskkill //F //PID <n>` (double slash).

- **`docker exec -i ... psql ... < file.sql` from Git Bash works** but make sure the file path is the Windows path (`/c/Users/...`) since the shell resolves it before docker sees it.

## Companion docs

- `docs/superpowers/specs/2026-05-21-whatsub-ios-mobile-v1-design.md` — full v1 spec (3 features, scope, architecture)
- `docs/superpowers/plans/2026-05-21-backend-library-sync.md` — Plan 1 (DONE: backend `/api/library/*` shipped)
- `docs/superpowers/plans/2026-05-21-ios-scaffold-and-ci.md` — Plan 2 Phase 1 (this scaffold + CI + TestFlight)
- Future: `docs/superpowers/plans/<date>-desktop-library-sync.md` (Plan 3) + `<date>-ios-phase2-features.md` (Plan 2 Phase 2)
