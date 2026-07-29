# whatsub-mobile — Architecture

iOS consumer client for whatSub. SwiftUI native, iOS 16+. Reads public/private corpus + cloud-synced library subtitles from the [whatsub-license](https://github.com/rjxznb/whatsub-license) backend. Companion to the [desktop Tauri app](https://github.com/rjxznb/whatsub-releases) (private repo for source) which produces the data this app consumes.

**Status**: v1 + post-v1 features live; App Store 1.0.0 shipped (hotfixes must bump `MARKETING_VERSION`, see pitfalls). Three tabs: Library / 语料库 / 我的. Shipped features (details in "Post-v1 features" below):

- **Self-hosted video** — native AVPlayer from Aliyun OSS+CDN (免VPN, instant seek), landscape→fullscreen, on-video bilingual captions + CC toggle; falls back to YouTube embed (需VPN badge per card).
- **Library** — swipe-to-delete (cloud row + OSS object), cache-first list (`GET /api/library/version` fingerprint), imported-cover thumbnail upload.
- **Import** — in-app YouTube import (pure-Swift Innertube, no WKWebView) → streaming LLM analysis → auto-sync; generic/non-YouTube URLs + caption-less videos route to the desktop import queue (yt-dlp + whisper → OSS 免VPN); desktop-presence hint; Live Activity for the queue wait.
- **语料库** — cloud personal + public corpus (unified store, no local vocab notebook); 平铺/分组 layout; delete from iOS; 待同步暂存 (collect→batch-sync) flow; flashcard quiz with IPA + persistent progress; persistent cache.
- **Practice** — per-video 角色扮演 (LLM voice dialogue), QuickChat orb, 拍照识别短语 (Vision OCR + LLM, photo never leaves device).
- **Billing** — single-subscription model: free vs Pro (`whatsub_pro_month` ¥38/月 OR `whatsub_pro_year` ¥348/年; SKU ids fixed, price is ASC-tier-driven via `product.displayPrice`). Pro unlocks public corpus + 50 视频 × 500MB × 60min + 1000 个人语料 + 5M token/月 managed LLM relay. Buyout + trial retired (no grandfathering needed — zero real purchases).
- **Managed LLM relay** (default ON) — all LLM calls route through `whatsub.eversay.cc/api/llm/chat` (server holds the DeepSeek key); shared monthly token quota (free 200K one-time / Pro 5M/mo). BYOK is opt-in advanced.
- **VPN routing UX** — Chinese users need 规则/分流 mode (not 全局); guidance surfaces + Shadowrocket screenshots.

## Stack

- **Swift 5.10 + SwiftUI** · iOS 16+ · Xcode 16+ (CI needs Xcode 26 SDK, see pitfalls)
- **XcodeGen 2.43+** generates `.xcodeproj` from `project.yml` (never edit pbxproj directly; `.gitignore`'d)
- **GitHub Actions (`macos-15`)** for CI + TestFlight upload
- **No third-party Swift deps** (URLSession, WKWebView, Keychain Services — all native)
- **App Store Connect API key** (`.p8`, Admin role) for fully-automated signing; no manual cert/profile management

## Repos this app talks to

| Repo | Role | URL |
|---|---|---|
| `whatsub-license` | Backend Hono+Postgres, owns `/api/auth/*`, `/api/corpus/*`, `/api/library/*`, `/api/llm/*` | https://github.com/rjxznb/whatsub-license |
| `whatsub-releases` | Desktop Tauri app source (private mirror at `rjxznb/whatsub`) — produces the library data we sync | — |
| `whatsub-website` | Marketing static site at `https://whatsub.eversay.cc` | https://github.com/rjxznb/whatsub-website |

## Layout

```
whatsub-mobile/
├── project.yml              # XcodeGen spec — single source of truth for .xcodeproj
├── ExportOptions.plist      # xcodebuild exportArchive config (method=app-store)
├── whatsub-mobile/          # Swift source target (note: same name as repo root)
│   ├── App/                 # @main + AppState + Theme + LiveActivityCoordinator
│   ├── Library/ Corpus/ Import/ Practice/ Photo/ Vocab/ Store/ Networking/ Components/
│   ├── Assets.xcassets/  Info.plist  PrivacyInfo.xcprivacy
├── whatsub-share/           # Share Extension target
├── whatsub-widget/          # Live Activity widget-extension target (iOS 16.2+)
├── Shared/                  # code compiled into multiple targets (AppGroup, ImportActivityAttributes)
├── .github/workflows/       # ci.yml (every push: sim build + screenshot) + testflight.yml (main: archive + upload)
└── docs/superpowers/        # spec + plans
```

## Apple Developer config (established)

- Team ID: `Q3BK52FQT9` · Bundle ID: `cc.eversay.whatsub.mobile` (share: `.share`, widget App Group: `group.cc.eversay.whatsub.mobile`)
- App Store Connect record: `whatSub` · Internal Tester: `2216681472@qq.com`
- App Review demo account: `appreview@eversay.cc` / `424242`
- GitHub Secrets: `APP_STORE_CONNECT_API_KEY_P8` (Admin-role .p8, PEM incl. headers), `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`; APNs: `APNS_KEY_ID` + `APNS_KEY_P8` + `APNS_TEAM_ID`. Delete .p8 from disk after upload; never commit.

## Build / dev

```bash
# Local (Mac with Xcode):
brew install xcodegen && xcodegen generate && open whatsub-mobile.xcodeproj
# CI does this on every push. Without a Mac: edit .swift/project.yml/workflows on Windows,
# push, watch CI artifacts (screenshots) for visual feedback.
```

## Key design decisions

- **XcodeGen, not Tuist**: XcodeGen YAML is editable from Windows (Tuist's Swift DSL needs macOS).
- **Automatic signing + ASC API key**: `-allowProvisioningUpdates -authenticationKey*` fetches a fresh distribution cert + profile per CI run. No local cert management ever; cost is every Archive talks to Apple's API (and mints a cert — see cert-cap pitfall).
- **Chinese-only UI hardcoded**: matches desktop, no i18n. `developmentLanguage: zh-Hans`.
- **iOS 16 minimum** (16.2 for Live Activity paths): NavigationStack + AsyncImage + `.foregroundStyle`; ~94% of devices in 2026.
- **0 third-party Swift packages**: auditable + reproducible builds; trade-off is more boilerplate.

## Post-v1 features (file ownership + non-obvious decisions)

### Self-hosted video (OSS + CDN + AVPlayer)
`AVPlayer` is owned by `LibraryDetailView` `@State(avPlayer)` and passed into `VideoPlayerView` (which no longer builds its own) — fixes the portrait↔landscape restart. Captions render to `AVPlayerViewController.contentOverlayView` (UIKit) so they show in native fullscreen incl. iPad. Plays via `Components/VideoPlayerView.swift` when backend returns `videoUrl` (signed Aliyun CDN, 2h TTL); else `YouTubeEmbedView`. `SubtitleOverlayView` composited over player + CC toggle. 15s loading timeout → VPN hint (YouTube path only; OSS is China-reachable).

### Library
- **Swipe-to-delete**: `.swipeActions` → confirm → `DELETE /api/library/sync/:id` (backend also drops the OSS object) → removes locally. Delete is alert-only (no migrate branch since the local vocab notebook was killed).
- **List cache** (`LibraryCache`, `Caches/library_cache.json`): cache-first; refresh hits `GET /api/library/version` (`MAX(synced_at)+COUNT(*)`) and only refetches `/list` on mismatch. Two differences vs `CorpusCache`: `fetchedAt > 0` marks "has cache" (empty library is valid), and cache records `ownerEmail` (checked on read → logout/login can't leak the prior user's list). Version probe best-effort. Cached signed URLs go stale — playback re-fetches `/entry/:id`; list only reads `videoUrl` nil-ness for the 免VPN badge.
- **VPN badge**: 免VPN (blue, `videoUrl != nil`) vs 需VPN (gray, tappable → VPN help). Imported videos upload a thumbnail (`i.ytimg.com/.../mqdefault.jpg` → `thumbData`).

### Import
- **In-app flow** (`Import/`): `YouTubeCaptionExtractor` (Innertube, see below) → `parseTimedtextJson3` → `AnalysisEngine` (streaming) → auto-sync `POST /api/library/sync`. Flow: `粘 URL → 手机解析 → extract → analyze (streaming + ETA) → sync → done`, zero mid-stage confirmation. `ImportViewModel.run(urlOrId:token:email:)` chains into `sync()` directly. `.error` screen has 「重试 AI 解析」 (`retryAnalysisOnly` — rawCues stay cached, skips re-extract). 手机解析 is the primary button; 推送到桌面端 secondary (trade-off: phone-parsed = YouTube-embed 需VPN, desktop-parsed = OSS 免VPN).
- **Cancellation (2026-07-20)**: `ImportViewModel` OWNS the task (`start`/`startRetryAnalysis`/`cancelWork`). `AnalysisEngine.analyze` calls `Task.checkCancellation()` at entry + between batches + before phase 2; `performAnalysis` re-checks before `sync()` (that's what keeps a cancelled import out of quota). `ImportView`'s ROOT `.onDisappear` fires `cancelWork()` (sheets on top don't). **Gotcha**: phase-2 `catch` swallows summary failures but must re-throw `CancellationError` explicitly, else a cancel returns a result and syncs anyway.
- **Push to desktop queue**: `enqueueImport` → `POST /api/library/import-queue`; desktop poll runs yt-dlp + whisper + LLM + sync. 我的→「导入队列」 shows status + failure reason + 重试 (re-enqueue→pending). Generic non-YouTube URLs (`VideoSource` classifies) auto-route here; playback shows "在桌面端查看" placeholder until OSS video exists.
- **Desktop-presence hint (2026-07-20)**: backend records `desktop_presence` (email→last_seen), bumped ONLY by desktop-made requests (30s `GET /import-queue?status=pending`, claims, non-pending status writes — `status='pending'` excluded because that's ALSO the iOS retry). `POST`+`GET /import-queue` return `desktopSeenSecondsAgo` (nil = never/old backend). iOS treats >120s or nil as offline → yellow "桌面端似乎不在线" callout + queue banner. Zero desktop-client change.
- **Live Activity (2026-06-18/19)**: `whatsub-widget` target (16.2+) renders aggregate `(inProgress, completed, failed, recentTitle?)` on lock screen + Dynamic Island. `Shared/ImportActivityAttributes.swift` compiled into both targets. `App/LiveActivityCoordinator.swift` (`@available(iOS 16.2,*)` `@MainActor` singleton): `ensureActivity(...)` idempotent + gated on `areActivitiesEnabled` + listens `activity.pushTokenUpdates` → POSTs tokens; `endIfStale()` 2-phase 10-min latch. Bearer from `KeychainStore.load()?.sessionToken` (decoupled from AppState — tokens deliver outside the view tree). Triggers: `pushToDesktop` after enqueue; `scenePhase == .active` → `endIfStale()`. Deep links `whatsub://import-queue` + `whatsub://library` drive `AppState.selectedTab`. Backend: `live_activity_tokens` table + `apnsPush.ts` fan-out. **Info.plist MUST declare `NSSupportsLiveActivities: true`** or every `Activity.request` silently no-ops.

### iOS Native YouTube Caption Extraction via Innertube (2026-06-19)
Pure-Swift HTTP client calling Innertube `/v1/player` (no WKWebView/JS/BotGuard/PO_TOKEN — Android-claiming clients can't be JS-attested). `Import/YouTubeCaptionExtractor.swift` (~150 LoC): two calls (POST player → GET timedtext fmt=json3), reuses `parseTimedtextJson3`, permanent disk cache `Caches/yt_captions/<id>.json` via `Import/CaptionCache.swift`. **4-client fallback chain** (mirror `yt-dlp .../youtube/_base.py INNERTUBE_CLIENTS` when YouTube changes anything): `ANDROID_VR` → `TVHTML5_SIMPLY_EMBEDDED_PLAYER` → `IOS` (clientVersion 21.02.3 / iPhone16,2 / iOS 18.2 — stale metadata → HTTP 400) → `MWEB`. Chain catches ALL `CaptionError` types (status + transport), continues on each, throws only when all exhausted (status-based exhaustion takes precedence). Risk: ANDROID_VR may need PO_TOKEN eventually → try TV clients; last resort backend yt-dlp service.

### Streaming LLM analysis + JsonLineParser (DeepSeek v4, 2026-06-21)
Mirror of desktop `analyze.ts`+`streamingJson.ts`. Why: `deepseek-chat`/`deepseek-reasoner` retired 2026-07-24; V4 (`deepseek-v4-flash`/`-pro`) emit long JSONL overflowing non-stream `max_tokens=4096` and put content in `reasoning_content`. `JsonLineParser.swift` buffers SSE, splits on `\n`, fires per `{...}` line (tolerates interleaved prose). `ChatCompletionsClient.streamChat` uses `URLSession.bytes + .lines`, yields `delta.content` else `delta.reasoning_content`, `max_tokens=16384` + 300s. `AnalysisEngine.analyze` streams batches → `parseCue`/`parseSummary`, per-cue progress; summary failure keeps per-cue results. Single-shot calls (QuickChat/CollectSheet/Roleplay/Photo) still use non-streaming `chat()`.

### 语料库 unified store (Stages 1-6, 2026-06-03)
Folded the old per-video local 词汇本 into the cloud 个人语料库. End state: ONE server store + ONE local staging area (`pending_phrases.json`) + context-specific UI over the same `MineItem`s.
- **`PhraseSource: Encodable`** (`DTOs.swift`) factory `.library/.photo/...` carries the `contributePhrase` payload. `CorpusSource` (response) gained `libraryEntryId` + `youtubeId` + `url: String?` (Library phrases need no url). `Corpus/PhrasePlayerView.swift` owns the routing matrix: `library`→resolve entryId→OSS AVPlayer (YT-embed fallback if deleted); `youtube`→YT embed; `webpage/pdf/manual`→SafariView.
- `LibraryDetailViewModel.seekTo(seconds:)` lets external phrase rows drive the main AVPlayer.
- `CorpusView` 平铺/分组 toggle (`@AppStorage("corpus.mine.layout")`); `GroupedMineView` clusters by `libraryEntryId→youtubeId→url→kind`, single-expanded-card invariant (parent-owned `expandedGroupId`) bounds OSS round-trips; group avatar = real OSS cover for library kind.
- Library detail `字幕 / 收藏 / 角色扮演` picker; `EntryCollectionsList` filters `mineCorpus` by `source.libraryEntryId == entryId`, cards match CueRow geometry (22pt EN / 16pt CN / 10×14 pad), tap → `vm.seekTo`.
- Killed `Vocab/VocabStore`, `VocabModels`, `VocabNotebookView`, `MigrateVocabSheet`, `VocabPracticeLauncherView` (−639 lines); local-only, never synced, no data loss.

### 待同步暂存 — collect→batch-sync (build 250)
Long-press subtitle → 「加入暂存」 → `Documents/pending_phrases.json` (no network/quota). `Vocab/PendingPhraseStore.swift` (file-backed `ObservableObject`, atomic save, `byVideo`). `Vocab/PendingPhrasesView.swift` sheet: multi-select / 全选 / 「同步选中的 N 条」 / per-row error / top banner. Entry points: `LibraryDetailView` `📥 待同步 N 条` pill (this entry) + 我的→工具 (global). Sync loops existing `/api/corpus/contribute`; succeeded items leave, failed stay inline, 413 stops the batch + Pro upsell. Deleting a Library video clears its pending phrases (`removeAll(entryId:)`; synced ones untouched).

### Delete personal corpus + cross-platform sync fix (build 250)
`CorpusView` flat List `.swipeActions`; `GroupedMineView` `.contextMenu` (swipe is List-only). Both → `pendingDelete: MineItem?` → tab-level alert → `DELETE /api/corpus/contribute/:id` + local `CorpusCache.storeMine` write-through. `MineItem.contributionId: Int?` (decoded from wire `id`; backend emitted it all along). **Backend fix** (`bf33de1`): `getMineVersion`/`getPublicCorpusVersion` → `COALESCE(MAX(contributed_at),0) + COUNT(*)` so deleting a non-most-recent row still shifts the fingerprint (was bare `MAX` → stale cache up to 24h TTL). Wire still a single number; equality compare unchanged.

### Per-video 角色扮演 (build 247-248)
Library detail's third tab. LLM derives 1-3 scene cards (title + subtitle excerpts + this video's corpus phrases) → pick → QuickChat orb shell. Reuses `ConversationEngine` + `VerdictParser` + `VoiceOrbView` + `VoiceActivityRecorder` + `ProductionProgressStore`; only `RoleplayPrompts.turnSystemPrompt` changes (in-character, English body, same `<<<VERDICT>>>` sentinel → per-phrase mastery). Files in `Practice/Roleplay/`. 8-turn cap; stock "随便聊聊这个视频" fallback when LLM unreachable. Trims desktop's forensic-report call + LearnerProfile persistence. Scenarios cached to `Caches/roleplay_scenarios.json` (invalidated by entryId + phrase fingerprint) + 「重新生成场景」. `vocabHints` hard-capped 5 (prompt + client `.prefix(5)`). Turn N/8 shown (phrase-drill mode hides it). Session start pauses the underlying video; leaving Library detail (tab switch or pop) pauses via root `.onDisappear` (sheets don't trigger).

### 拍照识别短语 (2026-06-04)
我的→拍照识别短语→相机/相册→local Vision OCR (`VNRecognizeTextRequest`)→one LLM call (整段翻译 + 3-8 短语)→`BilingualHighlightView` (原文/翻译/短语多选)→corpus `kind="photo"`. `Photo/` 8 files ~1160 LoC, no deps. **App Review**: `NSCameraUsageDescription` + `NSPhotoLibraryUsageDescription` state 照片不上传服务器 (only OCR text leaves); Privacy Nutrition Label "Photos - Not Collected". Backend `CorpusSource.kind` union extended to `'photo'`.

### Managed LLM relay (server-side, default ON, 2026-06-04)
All LLM calls default to `whatsub.eversay.cc/api/llm/chat` (server holds DeepSeek key); three clients share a monthly token quota (free 200K one-time / Pro 5M/mo). `LlmSettings.useRelay` default ON; BYOK opt-in. MeView LLM settings on 403 `license_blocked` shows one-tap 「关闭托管→切 BYOK」 (for grandfathered buyout users whose sub expired). Backend `routes/llm.ts` three-tier auth, `llm_usage` table per `(email, period_month)`, `stream_options.include_usage` for real billing. `LlmSettingsView` warns when BYOK is filled but relay left ON (settings persisted but `resolveConfig()` ignores them) + one-tap 「关掉托管」.

### Billing / subscription (single-subscription model, 2026-05-28; price bumped 2026-07-25)
App installs usable; only 免费版 / 已订阅 Pro states. Pro = `whatsub_pro_month` ¥38/月 OR `whatsub_pro_year` ¥348/年. **Prices are NOT hardcoded** — all UI shows `product.displayPrice` (StoreKit reads the ASC tier); changing the ASC price + backend `.env` `SUB_MONTH_PRICE_CNY`/`SUB_YEAR_PRICE_CNY` (Alipay web charge) propagates with no new binary. Website prices in `whatsub-website/src/lib/constants.ts`. StoreKit 2 `Transaction.updates` + `POST /api/license/iap/verify` (JWS). CorpusView public 403 → contextual `SubscribeSheet`; ImportView quota wall → `SubscriptionOptionsView`. Backend `hasCorpusAccess = license OR iosBuyout(grandfathered) OR hasActiveSubscription`. `MeResponse` decodes merged `hasActiveSubscription` (web OR iOS) — web/Alipay subscribers show 已订阅 Pro and hide the StoreKit subscribe button (管理订阅 stays iOS-only, no web redirect, per 3.1.1). Buyout (`fullunlock`) + trial fully retired from ASC + code (`PaywallView` deleted, DTOs dropped `iosBuyout`/`trialExpiresAt`/`appUnlocked`). Backend IAP verifier has prod+sandbox fallback (`appleVerifier.ts verifyWithFallback`) — Apple auto-routes TestFlight=sandbox, App Store=production.

### Login rate-limit awareness (build 231)
Backend `/auth/{send-code,verify-code}` rate-limited (`whatsub-license/src/lib/authRateLimit.ts`). Client: `APIError.rateLimited(scope, retryAfterSec, message)` parses 429 body + `Retry-After` header; `AuthViewModel.sendBlockedUntil` (local 30s soft cooldown < server's 60s window) read inside `TimelineView` for a per-second countdown; `AuthGateView` shows "请等待 N 秒". Server policy is authoritative — edit `authRateLimit.ts` only.

### VPN routing UX (Chinese users, reworked 2026-07-20)
iOS can't bypass system VPN per-request (no public API for packet tunnels), so guidance lives on the user's VPN side. **Insight**: users don't need to toggle VPN — both hosts resolve to Chinese Aliyun IPs and every mainstream rule set ships `GEOIP,CN,DIRECT`, so 规则/分流 mode routes whatSub direct + YouTube via proxy simultaneously. Only 全局 mode breaks us. NOTE it's GEOIP that saves us, not any vendor rule (`eversay.cc` is our domain) — so the explicit `DOMAIN-SUFFIX,eversay.cc,DIRECT` rule must stay for fake-ip DNS / slimmed rule sets.
- `VPNRuleHelpSheet.swift` — Tier 1 "切到规则模式就行" + Shadowrocket screenshot; Tier 2 (collapsed) explicit rule snippets + 3-shot walkthrough. Assets `Assets.xcassets/VPNGuideShadowrocket` + `VPNRuleShadowrocket{1,2,3}`; both `screenshotView` + `stepStrip` gate on `UIImage(named:)`. **Crop screenshots first** — originals carried the user's own 机场 domain/expiry/traffic.
- Entry points: onboarding on first launch only if `VPNDetector.isVPNActive()` (deferred behind AI-consent sheet); 我的→工具 row; Library error state; tappable 需VPN badge (`.borderless`).
- `VPNDetector.swift` — `CFNetworkCopySystemProxySettings()["__SCOPED__"]` keys vs `utun/tun/tap/ppp/ipsec`. Public-API heuristic (only gates showing guidance); pure `containsVPNInterface` with tests.
- `RelayLoadingView.swift` — 5s stall → yellow shield + 「查看 VPN 设置方法」. The real network call IS the probe. Wired into Library 收藏 + 角色扮演 tabs.

### Share Extension
`whatsub-share/` target (`cc.eversay.whatsub.mobile.share`), shares `group.cc.eversay.whatsub.mobile` App Group with the main app (both need the entitlement + portal registration; `AppGroup.swift` in both `sources`). `ShareViewController.swift` extracts URL → writes `AppGroup.pendingImportURL()` → completes. Main app `scenePhase == .active` reads it → opens ImportView prefilled + auto-runs. **Cannot auto-launch the containing app** (see pitfalls — settled, don't retry).

## 踩过的坑 (avoid repeating)

### CI / GitHub Actions / iOS toolchain

- **GitHub Actions billing block on a private repo stops ALL workflows** ("recent account payments have failed…"), even Linux. Solo-dev fix: `gh repo edit <repo> --visibility public --accept-visibility-change-consequences` — public repos get unlimited free Actions (incl. macOS); secrets stay encrypted. Trade-off: code world-readable (fine when value is in the experience + backend).

- **XcodeGen 2.43+ emits `objectVersion 77` pbxproj, Xcode 16+ only.** Symptom: `project ... cannot be opened because it is in a future Xcode project file format (77)`. Fix: `runs-on: macos-15` (not `macos-14`).

- **Apple requires the iOS 26 SDK (Xcode 26+) for any upload as of 2026.** Symptom: `Validation failed (409) ... must be built with the iOS 26 SDK`. `macos-15` ships several Xcodes; default may be 16. Fix: `maxim-lobanov/setup-xcode@v1` with `xcode-version: latest-stable` early in both workflows; verify `xcodebuild -version` prints 26.x.

- **ASC API key with "App Manager" role CANNOT create Distribution certs.** Symptom: Archive fails `Your team has no devices from which to generate a provisioning profile` (misleading). Fix: create a new Admin-role key (roles can't be changed in-place — revoke + create + re-upload .p8). Forcing `CODE_SIGN_IDENTITY`/`CODE_SIGN_STYLE=Manual` are all futile until the role is fixed.

- **`CODE_SIGN_STYLE=Automatic` + forced `CODE_SIGN_IDENTITY` = conflict** (`... automatically signed ... but a conflicting code signing identity Apple Distribution has been manually specified`). Never set CODE_SIGN_IDENTITY anywhere under Automatic mode.

- **A team with zero registered devices fails even Distribution provisioning** (same misleading "no devices" error). Fix: add ≥1 iPhone UDID to the team (one-time).

- **Cloud signing mints a NEW Distribution cert per Archive; Apple caps ~2-3.** Symptom after frequent CI: `Your account has reached the maximum number of certificates` + `No profiles ... were found`. Fix (~2 min): developer.apple.com → Certificates → revoke older "Apple Distribution" certs (keep ≤1), then `gh run rerun <run-id>` (no new commit needed). Long-term: manual signing with an exported cert in a Secret (deferred — reintroduces the management this project avoids).

- **App Store rejects large app icons with an alpha channel.** Symptom: `Validation failed (409) Invalid large app icon ... can't be transparent or contain an alpha channel`. The 1024² must be RGB. Strip alpha (PowerShell fills with brand black to `Format24bppRgb`): `Add-Type -AssemblyName System.Drawing; $s=[Drawing.Image]::FromFile('icon.png'); $d=New-Object Drawing.Bitmap($s.Width,$s.Height,'Format24bppRgb'); $g=[Drawing.Graphics]::FromImage($d); $g.Clear([Drawing.Color]::Black); $g.DrawImage($s,0,0); $d.Save('icon.png','Png'); $s.Dispose(); $g.Dispose(); $d.Dispose()`.

- **After public App Store launch, the `MARKETING_VERSION` "train" is locked; re-uploading the same version → 409.** Symptom: `Invalid Pre-Release Train. The train version 'X' is closed` + `CFBundleShortVersionString must contain a higher version`. Every hotfix to a shipped version must bump `MARKETING_VERSION` in `project.yml`. Build number (`CURRENT_PROJECT_VERSION`/`BUILD_NUM`) auto-increment solves a DIFFERENT problem (duplicate build no.) — it doesn't bypass the train lock.

- **`-authenticationKeyPath` needs `-authenticationKeyID` + `-authenticationKeyIssuerID` non-empty**; the "flag is required" error usually means the SECRET env var is empty. `printf '%s' "$EMPTY_VAR" > file.p8` silently makes an empty file → cryptic downstream failure. Sanity-check `wc -c file.p8` > 200 in CI.

### Swift / SwiftUI

- **`.foregroundStyle(.whatsubAccent)` needs the static on `ShapeStyle`, not just `Color`** (leading-dot resolves against the parameter type). Pair every Color static with a `ShapeStyle where Self == Color` extension — see `App/Theme.swift`. (`.secondary` works because it's already a ShapeStyle static.)

- **Bare `catch {}` binds an immutable `error` constant** that shadows any property named `error` → `error = ...` fails "cannot assign ... immutable". Name the `@Published` `errorMessage`.

- **System large nav title is flaky** with a custom global `UINavigationBarAppearance` + full-bleed background + push/pop (collapses after pop, or reserves space with no text). Multiple structural attempts failed. Robust fix: drop the system large title, render a custom `Text` header + `.toolbar(.hidden, for: .navigationBar)` on the root (pushed detail keeps its own bar). See `Library/LibraryView.swift`. Trade-off: lose the shrink-on-scroll animation.

- **LLM/pipeline JSON is not schema-clean — decode external blobs leniently.** `analysisJson.subtitles[].keyNotes` is declared `[String:String]` but the pipeline occasionally nests an object as a value → strict decode nukes the whole entry ("数据格式不正确"). Use a tolerant helper (`Cue.lenientStringMap` in `DTOs.swift`). Anything LLM-produced gets defensive parsing at the boundary.

- **`AVPlayerViewController.transportBarCustomMenuItems` is tvOS-only** — breaks Archive on iOS. No clean iOS custom-control-bar API. Don't attempt.

- **Multiple default-style `Button`s in one `List` row all fire on a single tap.** Fix: `.buttonStyle(.borderless)` on each (captures only its own touch area).

- **SwiftUI auto keyboard-avoidance is FLAKY** with NavigationStack + `Color.ignoresSafeArea()` + `.safeAreaInset(edge:.bottom)` + `TextField(axis:.vertical)` (double-pad or no-pad, non-deterministically). Don't mix: opt out with `.ignoresSafeArea(.keyboard, edges:.bottom)` + drive `.padding(.bottom, keyboardOffset)` from `keyboardWill{Show,Hide}Notification`. Template in `QuickChatView.swift`.

- **Dragdown-to-dismiss keyboard gated on `@FocusState` can fall silent** (`@FocusState` desyncs from the real keyboard). Dismiss unconditionally: `UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)` (no-op when nothing has focus).

- **`TextField(axis:.vertical)` can't dismiss the keyboard with Return** (Return inserts a newline). Add a `.toolbar(.keyboard)` 完成 button: `@FocusState focused` + `.focused($focused)` + keyboard ToolbarItemGroup calling `focused=false` + the `sendAction` above. Template in `CueRowEditing.swift`.

- **`Result<Success, Failure>` requires `Failure: Error`** — `Result<[T], String>` is a compile error. Use a tiny custom enum (`enum DerivationOutcome { case success([T]); case failure(String) }`) instead of a one-case error type. (Hit in `RoleplayScenarioClient`.)

- **Refactoring `Networking/DTOs.swift` silently breaks the test target** (`@testable import` shares the DTOs). Before pushing a DTO change: `grep -rn "CorpusSource(\|MineItem(\|\.source\.url\b" whatsub-mobileTests`; give explicit inits the new field (nil ok), force-unwrap rotted-Optional fixtures with `!` (not `?? ""`) so a regression screams.

- **`AsyncImage` never retries after `.failure` + `URLCache.shared` may cache failures** → images stay broken after a network blip (common with VPN toggling). Use `Components/RemoteImage.swift`: `cachePolicy: .reloadIgnoringLocalAndRemoteCacheData` + `.task(id: (url, nonce, manualRetry))` + auto-retry once on `URLError`. Never use stock AsyncImage for a non-100%-available source in the China+VPN context.

- **Absolute dBFS VAD thresholds don't survive ambient noise** (orb stuck "listening"; rooms sit at -35..-28 dBFS). `VoiceActivityRecorder.swift` uses `AVAudioEngine` input tap + dual-signal end-of-turn: (A) relative dB `max(peak-15, -38 floor)`; (B) live ASR partial-result stability (end if partial unchanged 1.2s AND ≥1 word). Either fires first wins; live transcript returned via `onSpeechEnded`.

- **QuickChat: hold-orb pause dropped chunk 1** — on-device `SFSpeechRecognizer` sometimes resets an utterance without firing `isFinal`. Added `looksLikeRecognizerReset` heuristic (old partial's last 12 chars absent from new partial → drain to `finalizedSegments`).

### Share-to-import + Share Extension

- **WKWebView default iOS UA makes YouTube serve the mobile-web player, migrating timedtext to `youtubei.googleapis.com/v1/player` → old hooks silently fail.** (Historical WKWebView path — superseded by Innertube.) General lesson: any WKWebView embedding a third-party SPA should pin the UA to a mainstream desktop Chrome build, or the feature dies silently with the vendor's mobile-policy changes (no 4xx, no error).

- **(SUPERSEDED by Innertube path.)** Historical: YouTube web-client timedtext required a `po_token` (2024) → the old fetch-hook-in-WKWebView workaround. The "no clean URLSession path" conclusion was wrong — Innertube via an Android-claiming client bypasses BotGuard + PO_TOKEN.

- **Share extension opening a deep-link can freeze the host app ~30s on return.** Three additive causes: (1) `extensionContext.open` in `viewDidLoad` (too early — our transparent view still eats touches); move to `viewDidAppear`. (2) `completeRequest` with no completion handler; use `completeRequest(...) { _ in ... }` + `withCheckedContinuation`. (3) responder-chain `perform("openURL:")` hack — dead + pokes host responder state. Template in `whatsub-share/ShareViewController.swift`.

- **You CANNOT auto-launch the containing app from a Share Extension on modern iOS** (settled 2026-07-20, device-verified, cost 3 attempts). `UIApplication.shared` is compile-time unavailable in extensions; `NSExtensionContext.open` is Today-extension-only and no-ops from a share sheet; responder-chain `perform("openURL:")` is dead (extension is its own process, no `UIApplication` on the chain, Apple closed it ~iOS 14). History: `2d6802d` added it claiming auto-launch → `042058d` removed it (YouTube freeze fix) → `079fa18` restored it → device test showed nothing → reverted `d8a43b8`. The "fallback makes it launch" claim was never verified — the AppGroup + `scenePhase` safety-net makes the import screen appear the instant the user switches to whatSub, indistinguishable from auto-launch. **Shipped behaviour (leave alone):** extension writes URL to App Group + completes; main app `scenePhase == .active` opens ImportView prefilled; user taps whatSub themselves. Rejected alt (extension pushes straight to desktop queue) removes the 手机解析 vs 推送到桌面端 choice.

- **`NSSupportsLiveActivities: true` in Info.plist is the admission ticket** — without it iOS silently rejects every `Activity.request(...)` (no error/log/token). First line of any ActivityKit Phase 0 checklist. `aps-environment` entitlement (APNs push) is a separate thing.

- **APNs JWT must use `signer.sign({key, dsaEncoding: 'ieee-p1363'})`** — Node's default DER ASN.1 → Apple `InvalidProviderToken`. `ieee-p1363` produces the raw 64-byte r||s Apple expects. (Backend `apnsPush.ts`.)

- **iOS 16.1 vs 16.2**: ActivityKit shipped 16.1 but `Activity.request(attributes:content:pushType:)` + `ActivityContent` + `Activity.end(_:dismissalPolicy:)` are 16.2-only. Target 16.2 for the modern ContentState + push.token path. nginx needs a `location /api/live-activity/` block (missing → 405 from nginx, not 401 from Hono).

- **DeepSeek v4 puts the answer in `reasoning_content`, `content` is `""`; `??` doesn't trigger** (`""` is non-nil). Trim `content` first, fall back to `reasoning_content` only if empty. Real fix is streaming (see Streaming LLM analysis).

### Networking / China reachability

- **`i.ytimg.com` (YouTube thumbnail CDN) is GFW-blocked** — no VPN → thumbnails don't load (placeholder). YouTube embed has the same constraint (already 需VPN to watch). Proper fix (deferred): sync desktop's local thumb.jpg to our China-reachable backend.

### Local dev on Windows

- **`localhost` curl hits `http_proxy` instead of loopback** with Clash env set (symptom: 502 with proxy headers). Fix: `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY` or `curl --noproxy '*'`.
- **Git nags LF→CRLF on `git add`** — cosmetic (blob stores LF). Silence with `.gitattributes` `* text=auto eol=lf` (not done — noise, not breaking).
- **`taskkill /F /PID <n>` from Git Bash fails** ("无效参数 - 'F:/'", MSYS path translation). Use PowerShell `Stop-Process -Id <n> -Force` or `taskkill //F //PID <n>`.
- **`docker exec -i ... psql ... < file.sql` from Git Bash** works — use the Windows path (`/c/Users/...`), the shell resolves it before docker.

### Backend deploy (whatsub-license on Aliyun)

- **Admin SPA (`public/admin/index.html`) is baked into the container image** (`COPY public ./public`, WORKDIR `/app`) but `serveStatic` reads from disk per request. For a single static-file fix: `scp` to server → `docker cp <file> whatsub-license:/app/public/admin/index.html` (no restart needed). Verify with `docker exec whatsub-license grep ...`.
- **Alipay subscription price is env-driven** (`SUB_MONTH_PRICE_CNY`/`SUB_YEAR_PRICE_CNY` via `requireEnv` in `src/index.ts` → `payment.ts`); live value is in the server's `/opt/whatsub/.env`, NOT the code. `.env.example` is documentation only.
- **Alpine.js `x-for` evaluates eagerly even under a false `x-show`** — `x-for="a in detail.activations"` on a null `detail` throws and breaks the whole component's handlers. Use `x-for="a in (detail?.activations || [])"`.
- **Alpine.js `x-if` on modals nested inside `x-show` sections fails silently** (2026-07-25) — Admin panel's subscription expiry editor modal used `<template x-if="expiryEditor">` inside `<section x-show="tab === 'subs'">`. Button click set `expiryEditor = {...}` but the modal never appeared. Alpine's `x-if` reactivity breaks when the template is inside a conditional parent. **Fix**: (1) move modal to Alpine root element top level (outside all `x-show` sections), OR (2) replace `<template x-if>` with `<div x-show>` + `x-cloak`. Option 2 is simpler for modals (keeps them near their trigger). Guard `x-text`/`x-model` inside with `expiryEditor?.field` or `expiryEditor && method(expiryEditor.field)` since `x-show` keeps the element in DOM even when hidden (vs `x-if` which removes it). Trade-off: `x-show` renders on page load (hidden), `x-if` only when truthy — for heavy modals prefer `x-if` at root level; for simple ones `x-show` is fine.

## Desktop replacement of a YouTube Library entry (2026-07-29)

An iOS Library detail whose authoritative `sourceUrl` is an allowed YouTube host,
whose parsed ID matches `youtubeId`, and which has no OSS `videoUrl` can send the
existing entry to the same-account desktop client. It enqueues exactly
`{ url, mode: "replace", targetLibraryEntryId }`; this is not a new Library
import. Pending or processing replacements for that target disable another send.
The detail refreshes on foreground/pull-to-refresh and switches to the existing
OSS AVPlayer path once the completed entry exposes `videoUrl`.

`maxVideoSeconds` is server-authoritative. Before enqueue, iOS blocks only when
both the entry duration and that account limit are known and the duration is
greater than the limit; equality and an unknown value proceed to backend and
desktop validation. After enqueue, the existing desktop-presence signal warns
when it is absent or older than 120 seconds, but it does not prevent the request.

Replacement work is deliberately fail-safe: the desktop stages queue-scoped
media and asks the backend to atomically update the same Library row and finish
the queue job. A failed download, analysis, staging, or completion leaves the
Library row, its ID, and its corpus collections unchanged; only the replacement
queue job becomes failed. Retrying a failed replacement reuses the queue through
the backend's guarded reset, with fresh staging keys; completed jobs are terminal.

Compatibility and release order are mandatory: deploy the additive backend
schema/API and capability gate first, then release a desktop build that polls
with `supportedModes=import,replace`, and only then ship/expose this iOS action.
Legacy desktop pollers default to `import` and therefore cannot claim a
replacement job. Do not deploy the iOS UI before a compatible desktop release is
available.

## Companion docs

- `docs/superpowers/specs/` — v1 design + Innertube caption + Live Activity specs
- `docs/superpowers/plans/` — backend library-sync, iOS scaffold+CI, Live Activity plans
