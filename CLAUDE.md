# whatsub-mobile — Architecture

iOS consumer client for whatSub. SwiftUI native, iOS 16+. Reads public/private corpus + cloud-synced library subtitles from the [whatsub-license](https://github.com/rjxznb/whatsub-license) backend. Companion to the [desktop Tauri app](https://github.com/rjxznb/whatsub-releases) (private repo for source) which produces the data this app consumes.

**Status**: v1 + post-v1 features on TestFlight (2026-05-22/23). Phase 1 (scaffold + CI + TestFlight) ✅; Phase 2a (email-OTP auth) ✅; Phase 2c (Library list + bilingual subtitle reader) ✅; Phase 2b (语料库 browse + phrase detail) ✅. Backend thumbnail sync ✅. **Self-hosted video** ✅: native AVPlayer from Aliyun OSS+CDN (no VPN, instant seek), landscape→fullscreen, on-video bilingual captions + CC toggle, player loading overlay + VPN hint; fallback to YouTube embed. **Swipe-to-delete** ✅: left-swipe a Library card → confirm → removes from cloud (backend row + OSS object). **Share-to-import** ✅: in-app YouTube import (pure-Swift Innertube `/v1/player` as ANDROID_TESTSUITE → timedtext, no WKWebView/JS injection — see «iOS Native YouTube Caption Extraction via Innertube» below) + LLM analysis (user's openai-compatible key, client-side) → preview → sync; Share Extension (YouTube/Safari → whatSub via App Group + `whatsub://` deep link); push caption-less videos to desktop import queue. **Library VPN badge** ✅: 免VPN (OSS-hosted) vs 需VPN badge per card; imported videos upload their cover thumbnail. **Generic URL import** ✅: any non-YouTube URL (Bilibili first) auto-routes to the desktop import queue (desktop yt-dlp + whisper transcribes the English audio → OSS self-hosted → plays 免VPN); `VideoSource` classifies the URL (YouTube keeps the client-side caption path), and playback guards against ever embedding a non-YouTube id (shows a "在桌面端查看" placeholder when no OSS video); the 我的 tab has a 「导入队列」 view surfacing each push's status + failure reason with a 重试 (re-enqueue → reset to pending) button. **单词卡测验** ✅: 语料库 tab → a flashcard multiple-choice quiz (英→中, 4 options, wrong→✗+retry, correct→inline reveal) over the 公共/个人 corpus phrases, with persistent local progress (`Documents/quiz_progress.json`, mastery threshold + weighted selection), IPA phonetics under each prompt (bundled offline en-US dict `Resources/ipa-en-us.json`, reused from the desktop, per-word lookup) + a correct-answer system sound + success haptic; client-side only, no backend change. **语料库持久化缓存** ✅: corpus list + tapped phrase lookups cached to `Caches/corpus_cache.json`, invalidated by `GET /api/corpus/versions` (`{mine,public}`) + 24h TTL + 500-entry LRU on lookups — cache-first (instant + offline), no per-tap server calls; no backend change. **Library 同步额度 + per-video cap** ✅ (2026-05-28): three-tier fence — free 3 视频 × 100MB × 20min / sub 50 视频 × 500MB × 60min。后端 `/upload-url` early-fail 413 + `/sync` HEAD-backstop (OSS object size 真实校验，恶意客户端伪造 contentLength 也会被拒+清理) + 客户端 pre-check (duration before transcode 省 ffmpeg CPU、size after) + 友好中文错误 dialog (`video_too_large` / `video_too_long`) with Pro upsell deep-linking to `https://whatsub.eversay.cc/mobile#pro`；`/me.libraryLimits` + `/quota.limits` 为客户端统一来源。 **iOS 收费 — 单一订阅模式 (policy shift 2026-05-28)** ✅: 退役 ¥18 一次性买断（`cc.eversay.whatsub.mobile.fullunlock` SKU 在 App Store Connect 完全删除——无任何真实购买记录、不需要 grandfathering）；移除 1 天试用门 + 全屏硬付费墙；app 安装即用，**只有「免费版」「已订阅 Pro」两种状态**。Pro = `whatsub_pro_month` **¥22/月** OR `whatsub_pro_year` **¥168/年** (2026-06-04 从 ¥12/¥88 上调,覆盖 managed-LLM relay 成本)；解锁公共语料库 + 50 视频 × 500MB × 60min + 1000 个人语料 + 5M token/月 LLM 中转。CorpusView 公共 tab 403 → 上下文 SubscribeSheet（不再是硬付费墙）；ImportView 配额墙 → SubscriptionOptionsView 内购；StoreKit 2 `Transaction.updates` 监听 + `POST /api/license/iap/verify` 上报 JWS。后端 `hasCorpusAccess = license OR iosBuyout(grandfathered, 无实际用户) OR hasActiveSubscription`，修复了之前只查 `iosSubActive` 漏掉 Alipay 时段会员的 bug。`PaywallView.swift` 已删除 (dead code)；StoreManager 移除 `buyoutProductID/Product/hasLocalBuyout/purchaseBuyout`；DTOs 移除 `iosBuyout` + `trialExpiresAt` + `appUnlocked`。** Three tabs: Library / 语料库 / 我的. **Video player fix (2026-05-25/26):** `AVPlayer` 提升到 `LibraryDetailView` `@State(avPlayer)` 并传入 `VideoPlayerView`（后者不再自建），解决横竖屏切换重启播放问题；字幕渲染到 `AVPlayerViewController.contentOverlayView`（UIKit），在原生全屏（含 iPad）也能显示。**Other fixes:** 订阅按钮在 List 行中同时触发 → `.buttonStyle(.borderless)`；Library 空态 iPad 居中；退出登录确认对话框；YouTube 真实标题 via oEmbed。**授权状态 + 语料配额服务端权威 (TestFlight #154, 2026-05-26)** ✅：`MeView` 授权状态行显示解锁来源（**网站授权 · 有效 / 已订阅 Pro / 免费版**，3 种状态；2026-05-28 政策变更后试用 + 买断已从产品里移除）；`CorpusView` 个人语料配额改读 `GET /api/corpus/quota`（服务端权威 `limit = hasActiveSubscription?1000:50`，正确反映支付宝/网页订阅；best-effort，失败回退本地计数 + `iosSubActive` 猜测）—— 后端同时新增该端点（`974be3f`，已部署 prod），与既有 `GET /api/library/quota` 对称。**网站 Pro 订阅入口** ✅: `whatsub.eversay.cc/mobile#pro` 上 Alipay 月/年订阅卡（`whatsub-website/src/components/ProSubscriptionCard.tsx`，2026-05-28），桌面 Get_Video 配额对话框 deep-link 到此；iOS 客户端默认走 Apple IAP（不能从 app 跳网站，App Store 反对引导）。**Next: App Store 公开上架**（env=Production + 演示账号 `appreview@eversay.cc` / `424242` 已就位 + iOS 6894c9f 含零买断/试用残留，即将提审）。 **语料库统一 + 协作打磨 (build 247-250, 2026-06-03/04)** ✅: Stage 1 — 长按字幕收藏改写到云端语料库（`PhraseSource.library(entryId, youtubeId)` 而非旧的本地 VocabStore），收藏的 phrase 自带 libraryEntryId 让客户端能直连 OSS AVPlayer 播；Stage 2 — `CorpusSource` 加 `libraryEntryId/youtubeId` 字段（url 变 Optional，Library 短语不强制有 url），`PhrasePlayerView` 路由 library→OSS / youtube→YT embed / webpage→Safari；Stage 3 — `LibraryDetailViewModel.seekTo(seconds:)` 新接口让外部短语行可以驱动主 AVPlayer；Stage 4 — `CorpusView` 加「平铺/按视频分组」layout 切换（持久化 `@AppStorage("corpus.mine.layout")`），`GroupedMineView` 按 libraryEntryId→youtubeId→url 聚类、每组单一展开 PhrasePlayerView 共享、tap 短语行 seek inline；Stage 5 — `LibraryDetailView` 加 `字幕 / 收藏 / 角色扮演` 三段 picker，`EntryCollectionsList` 列出本视频的 corpus 短语（filter by libraryEntryId），tap 驱动主 player seek；Stage 6 — 退役本地 `VocabStore` + `VocabNotebookView` + `MigrateVocabSheet`（−5 文件 −639 行），完全统一到云端语料库；**per-video 角色扮演对话** — LLM 基于视频字幕摘要 + 本视频收藏短语生成 1-3 个场景卡，挑一个进 QuickChat orb shell（复用 `ConversationEngine` + `VerdictParser` + `ProductionProgressStore`），新 system prompt 让 AI 留在角色里全英对话，每轮 `<<<VERDICT>>>` 命中的 vocab hint 写回 mastery store；**待同步暂存 (build 250)** — 字幕长按 → `CollectSheet` 写本地 `Documents/pending_phrases.json`（不再立刻消耗云端 quota），Library 详情页加 `📥 待同步 N 条` banner + 我的→工具→`待同步暂存`，多选 sync 时逐条 POST `/contribute`，413 quota 触发停 + Pro upsell；**iOS 删除语料 + 跨端同步** — `平铺 swipeActions / 分组 contextMenu` → 确认 alert → `DELETE /api/corpus/contribute/:id` + 本地缓存写回；后端 `getMineVersion`/`getPublicCorpusVersion` 改为 `MAX(contributed_at) + COUNT(*)`（之前是 MAX 单字段，删非最新行 fingerprint 不变，其他端等值比较缓存 24h 才感知；改完每次增/删都 bump，其他端自动重拉 `/mine`），已部署 prod。 **UI 打磨** — 收藏 tab 卡片放大到 CueRow 同款（22pt 英文 / 16pt 中文 / 10×14 padding）；语料库分组视图 group 头像换成真实 OSS 视频封面（仅 library kind，非视频 webpage/pdf/manual 保留 icon）。 **Managed LLM relay (server-side, default ON, 2026-06-04)** ✅: 所有 LLM 调用默认走 `whatsub.eversay.cc/api/llm/chat` 中转（服务端管理 DeepSeek API key）— 三端（桌面/iOS/插件）共享一个月度 token 配额：免费 200K 一次性体验包 / Pro 5M/月。客户端 `LlmSettings.useRelay` 默认 ON；BYOK（用户自配 openai-compatible key）退化为 opt-in 高级选项。`SubscribeSheet` 把"无需自配 API key"作为 Pro 第一卖点；MeView → LLM 设置遇 403 `license_blocked` 上下文显示「关闭托管 → 切 BYOK」一键按钮（针对 grandfathered 买断用户 sub 过期的窄场景）。后端 `routes/llm.ts` 三层鉴权（pro/trial/free），`llm_usage` 表按 `(email, period_month)` 累计 token，`stream_options.include_usage` 拿真实计费数据。订阅价同步上调到 ¥22/¥168（见前文）；SKU id 不变，ASC 改价即生效，无需新 binary。 **拍照识别短语 (2026-06-04)** ✅: 我的 → 拍照识别短语 → 相机或相册 → 本地 Vision OCR (`VNRecognizeTextRequest`) → 一次 LLM 调用同时完成"整段翻译 + 3-8 个重点短语提取" → `BilingualHighlightView` 三栏（原文 / 翻译 / 短语 list 多选）→ 选中的写到 corpus (`kind="photo"`，`PhraseSource.photo(localPhotoId:)`)。`Photo/` 目录 8 个文件 ~1160 行全 SwiftUI 无第三方依赖。**关键 App Review 项**：`NSCameraUsageDescription` + `NSPhotoLibraryUsageDescription` 文案明确写"照片本身不会上传到服务器"（只 OCR 提文本，照片永不离开本机），ASC Privacy Nutrition Labels 也要对应声明 "Photos - Not Collected"。后端 `parseSource` + `lib/types.ts` `CorpusSource.kind` union 扩到 'photo'（url 在 photo kind 时也可选）。 **Roleplay scenarios 持久化 (2026-06-04)** ✅: 场景卡缓存到 `Caches/roleplay_scenarios.json`（按 entryId + corpus phrase fingerprint 失效），重进 tab 不再烧 LLM call；UI 显示「上次生成 · X 前」+「重新生成场景」按钮（主动 invalidate）。 **Piper 离线 TTS 镜像兜底 (2026-06-04)** ✅: `PiperModelDownloader` 从单一 huggingface.co URL 改成 `[hf-mirror.com, huggingface.co]` 优先序列；国内首次下载秒成，HF 被 GFW 卡的场景自动 fallback。 **2026-06-04/05 collective polish** ✅: ① 删 Library 视频时清掉本视频的暂存 phrase（`PendingPhraseStore.removeAll(entryId:)`，已同步到云端的不动）；② 角色扮演 session 开启 → 暂停底层视频（`RoleplayTabView.onSessionStart` 回调挂到 `avPlayer?.pause()`）；③ Library 详情切到「语料库 / 我的」tab 或 pop 回列表 → 暂停视频（根 view `.onDisappear` hook，sheets 不触发不会误伤 shadow/cloze/collect/roleplay）；④ QuickChat 按住 orb 中途暂停不再丢 chunk 1 — SFSpeechRecognizer on-device 偶尔不触发 `isFinal` 直接 reset 当前 utterance，加 `looksLikeRecognizerReset` 启发式（旧 partial 末 12 字符在新 partial 里找不到 → drain 到 `finalizedSegments`）；⑤ 角色扮演 `vocabHints` 硬限 5（prompt 加约束 + 客户端 `.prefix(5)` 双层夹住，DeepSeek 常无视 prompt 多塞 7-10 条）；⑥ Roleplay 顶部显示「Turn N / 8」(`QuickChatViewModel.turnIndex` 提升到 `@Published`；phrase-drill 模式隐藏避免改变用户对"用完所有短语"目标的优化方向)。 **App Store 提审就绪 (2026-06-05)** ⚠ pending manual ASC config: 后端 IAP verifier 双环境 fallback 已就位（`appleVerifier.ts` 同时构建 prod + sandbox verifier，`verifyWithFallback` 任一通过即认）—上线无需新 binary。剩下 4 个**手动**预检：① ASC 订阅产品 attach 到这次提审的 binary version；② Paid Apps Agreement + 税表 + 银行账户必须 Active（缺一个 Apple 直接锁所有付费产品）；③ Privacy Nutrition Labels 加 Camera + Photo Library 用途（拍照识别要的）；④ Review Notes 描述拍照识别 / Roleplay / QuickChat 的测试路径 + 演示账号 `appreview@eversay.cc` / `424242`。沙盒沙箱 vs 生产环境靠 Apple 二进制自动路由：TestFlight 永远 sandbox，App Store 公开下载用户永远 production；客户端零改动，后端零改动。 **跨端订阅徽章修复 (2026-06-05)** ✅: `MeResponse` 之前只解 `iosSubActive`(StoreKit)，导致**在网页/插件用支付宝订阅、再用同邮箱登 iOS** 的用户被误标「免费版」且仍显示「订阅 Pro」按钮(诱导重复 StoreKit 扣费)——虽然后端功能层(公共语料 403 门 + 配额)早已按 `hasActiveSubscription` 解锁。修复：`MeResponse` 解码后端早已返回的合并字段 `hasActiveSubscription`(web OR iOS)；`MeView` 授权状态行 + 云端同步行的 Pro 徽章/upsell 改读它——web 订阅者显示「已订阅 Pro」并隐藏订阅按钮(「管理订阅」StoreKit 按钮仍仅 iOS 原生订阅显示，不引导跳网页，符合 App Store 3.1.1)。后端无需改动/重部署(字段早在线上)。需 Xcode build + 重新提审。

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

**In-app import flow** (`Import/` views): a URL field in the 我的 tab → pure-Swift `YouTubeCaptionExtractor` (calls YouTube's Innertube `/v1/player` as `ANDROID_TESTSUITE` over plain URLSession — no WKWebView, no JS injection, no PO_TOKEN; see «iOS Native YouTube Caption Extraction via Innertube» below for the full rationale) → `parseTimedtextJson3` (json3 → `[Cue]`) → `LLMAnalyzer` (user's openai-compatible key from Keychain; chunks cues → `/chat/completions` → `AnalysisJson`) → `ImportFlowView` preview (reuses bilingual cue renderer) → "同步到云库" → `WhatsubAPI.syncLibraryEntry` → `POST /api/library/sync`.

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

### 语料库统一 (Stages 1-6, 2026-06-03)

Six-stage refactor folding the old per-video local 词汇本 into the cloud 个人语料库, with new mechanics layered on top. End state: ONE store of record (server) + ONE local staging area + UI surfaces that route the same `MineItem`s differently per context.

**Stage 1 — `PhraseSource` schema unified.** New `PhraseSource: Encodable` (`DTOs.swift`) with factory `.library(entryId, videoTitle, youtubeId, timestampSec)` carries the full payload `contributePhrase` needs. `CollectSheet.save()` now builds one of these instead of the old (deleted) `VocabStore.shared.add(...)` path.

**Stage 2 — `CorpusSource` (response side) gained `libraryEntryId` + `youtubeId` + `url: String?`** (url no longer required because Library-anchored phrases don't need one). New `Corpus/PhrasePlayerView.swift` routes a source to the right player at display time: `kind == "library"` → resolve `libraryEntryId` → OSS `AVPlayer` (with YT-embed fallback when entry deleted but youtubeId present); `kind == "youtube"` → YT embed; `kind == "webpage"|pdf|manual` → SafariView ("打开来源"). One file owns the routing matrix.

**Stage 3 — `LibraryDetailViewModel.seekTo(seconds:)`** new overload (existing one only took a `Cue`). Lets `EntryCollectionsList`'s phrase rows drive the main `AVPlayer` without manufacturing fake cues.

**Stage 4 — `GroupedMineView` ("按视频分组" layout).** `CorpusView` has a 平铺/分组 segmented toggle persisted via `@AppStorage("corpus.mine.layout")`. Grouped mode renders one expandable card per video, keyed by `libraryEntryId → youtubeId → url → kind`. Inside an expanded card: ONE shared `PhrasePlayerView` (rendered once, seeked by tap on phrase rows); rows for non-video kinds become "打开来源页面" → SafariView sheet. Single-expanded-card invariant via parent-owned `expandedGroupId` keeps OSS round-trips bounded.

**Stage 5 — Library detail's `字幕 / 收藏 / 角色扮演` segmented picker.** `EntryCollectionsList` filters `mineCorpus` items by `source.libraryEntryId == entryId` and renders them as cards matching CueRow geometry (22pt English / 16pt Chinese / 10×14 padding / cornerRadius 10) — the tab feels like a continuation of the subtitle reading surface, not a denser secondary list. Tap a row → parent `vm.seekTo(seconds:)`.

**Stage 6 — Killed the local vocab notebook.** Deleted `Vocab/VocabStore.swift`, `Vocab/VocabModels.swift`, `Vocab/VocabNotebookView.swift`, `Vocab/MigrateVocabSheet.swift`, `Practice/QuickChat/VocabPracticeLauncherView.swift` (−639 lines). LibraryDetailView lost its toolbar 词汇本 button, LibraryView lost the migrate-before-delete sheet branch (delete is now alert-only), MeView lost the 词汇暂存区 entry. No data loss in practice — the old notebook was local-only, never synced.

### Per-video 角色扮演 (LLM voice dialogue scoped to a Library video, build 247-248)

Library detail's third tab. On open, an LLM call derives 1-3 short scene cards anchored to the video (title + subtitle excerpts + the user's own corpus phrases tagged to this video). User picks a card → a roleplay session opens in the existing QuickChat orb shell. Reuses `ConversationEngine` + `VerdictParser` + `VoiceOrbView` + `VoiceActivityRecorder` + `ProductionProgressStore` — only the system prompt changes (`RoleplayPrompts.turnSystemPrompt`: stay in character, English-only body, same `<<<VERDICT>>>` sentinel so per-phrase mastery still lands in `production_progress.json`).

Mirrors the desktop client's roleplay feature (`Get_Video/client/src/tutor`) in shape but trims:
- No separate post-session "forensic report" LLM call — per-turn verdict already feeds mastery; no third round trip.
- No LearnerProfile / ErrorEvent persistence — existing per-phrase mastery covers what the user actually sees.

Files in `Practice/Roleplay/`: `RoleplayModels.swift` (`RoleplayScenario` + lenient JSON decoder), `RoleplayPrompts.swift` (scene derivation + per-turn prompt), `RoleplayScenarioClient.swift` (one-shot LLM call → `[RoleplayScenario]`), `RoleplayScenarioCard.swift`, `RoleplayTabView.swift` + `RoleplayTabViewModel.swift` (state machine), `RoleplaySessionView.swift` (thin wrapper around `QuickChatView`'s new roleplay-mode init). 8-turn cap; fallback to a stock "随便聊聊这个视频" scenario when LLM is unreachable so the tab is never dead.

### 待同步暂存 — collect-then-sync flow (build 250)

Before: long-press subtitle → `CollectSheet` → 「加入」→ immediate POST `/api/corpus/contribute` (burned quota on every collect). After: 「加入暂存」→ writes to `Documents/pending_phrases.json` (no network, no quota), user reviews + batch-picks which ones to sync later.

Files: `Vocab/PendingPhraseStore.swift` (file-backed `ObservableObject`, atomic save, `byVideo` grouped helper), `Vocab/PendingPhrasesView.swift` (sheet with multi-select checkboxes / 全选 toolbar / bottom 「同步选中的 N 条」 button / per-row error inline / top banner for success or 413 quota hit with Pro upsell). Two entry surfaces: `LibraryDetailView` shows a `📥 待同步 N 条` pill between player and segmented picker (filtered to THIS entry); 我的 → 工具 → 「待同步暂存 (N)」 opens the global view (all videos grouped). Sync loops the existing `/api/corpus/contribute` — no new backend endpoint. Succeeded items leave the store; failed items stay with the error inline; 413 stops the batch since every following call would also 413.

### Delete personal corpus from iOS + cross-platform sync fix (build 250)

iOS UI: `CorpusView` flat List `.swipeActions(edge: .trailing)` destructive 删除; `GroupedMineView` LazyVStack `.contextMenu` 删除 on each phrase row (swipe-actions is List-only on iOS). Both feed `pendingDelete: MineItem?` for a single tab-level confirmation alert (anchors at safe area, doesn't clip on iPad). `CorpusViewModel.delete(item:token:)` calls `DELETE /api/corpus/contribute/:id` then removes from `mine` array + decrements `mineTotal` + writes through `CorpusCache.storeMine` so cold-start doesn't snap the row back.

DTO: `MineItem` gained `let contributionId: Int?` (decoded from wire field `id` via `CodingKeys`; backend has been emitting it all along — see `whatsub-license` `commit c713e26` — iOS just wasn't reading it). Optional for pre-decode cached payloads; when nil the UI surfaces "下拉刷新一次再试" rather than failing silently.

**Cross-platform sync fix in `whatsub-license`** (`bf33de1`, deployed 2026-06-03): `getMineVersion` and `getPublicCorpusVersion` were `MAX(contributed_at)` alone — deleting a NON-most-recent row left MAX unchanged, so other clients' equality-comparison cache stayed fresh up to 24h TTL. Fixed to `COALESCE(MAX(contributed_at), 0) + COUNT(*)` so every insert AND every delete shifts the fingerprint. Wire is still a single number; all clients keep doing equality compare. BIGINT overflow is a non-issue (epoch_ms ~1.7e12, COUNT capped at Pro tier's 1000 personal phrases; signed 64-bit holds ~9.2e18). Tests updated: existing assertions on raw MAX values bumped by +COUNT, new regression test specifically deletes a non-most-recent row + asserts the version changed.

### iOS Live Activity for desktop import queue (2026-06-18/19)

iOS surface for the long async wait while the desktop client downloads + transcribes URLs the user pushed via 我的→导入. New `whatsub-widget` app-extension target (iOS 16.2+) renders an aggregate Live Activity showing `(inProgress, completed, failed, recentTitle?)` on the lock screen + Notification Center (all 16.2+ devices) + Dynamic Island compact/minimal/expanded (iPhone 14 Pro+). Single Activity per device — backend fans out APNs HTTP/2 pushes to every registered token for the email so iPhone + iPad both see the same state.

**Architecture** (`docs/superpowers/specs/2026-06-18-ios-live-activity-import-queue-design.md` + `docs/superpowers/plans/2026-06-18-ios-live-activity-import-queue.md`):

- **Shared attrs**: `Shared/ImportActivityAttributes.swift` compiled into BOTH `whatsub-mobile` + `whatsub-widget` via per-target `sources:` (same pattern as `AppGroup.swift`). ContentState is `{inProgress, completed, failed, recentTitle?}`.
- **Backend** (`whatsub-license` commits `af1d99d` → `b4f54f1` + route + nginx): new `live_activity_tokens` table (PK `(email, activity_id)`), `Database.upsert/list/deleteLiveActivityToken` + `getImportQueueAggregateForEmail` + `getImportQueueTitle` (`title` column also added to `import_queue` via idempotent ALTER), `apnsPush.ts` module — ES256 JWT signer (`dsaEncoding: 'ieee-p1363'` — DER default → InvalidProviderToken) + `pushUpdate`/`pushEnd` + `pushQueueStateForEmail` (best-effort fan-out, reads APNS_* env at call time, silently no-ops if env unset). `POST /api/library/import-queue` + `/:id/status` + `/:id/claim` fire the hook AFTER successful mutation, gated on the mutation's success boolean so failed-no-ops don't push spurious state.
- **Routes**: `POST /api/live-activity/register {activityId, pushToken}` + `/end {activityId}`, both `requireSession` authed. nginx config (`whatsub-license/nginx/whatsub.conf`) needs a matching `location /api/live-activity/` block — symptom of missing block: 405 from nginx instead of 401 from Hono.
- **iOS coordinator**: `App/LiveActivityCoordinator.swift` — `@available(iOS 16.2, *)` `@MainActor` singleton. `ensureActivity(forUserEmail:initialState:)` is idempotent + gated on `ActivityAuthorizationInfo().areActivitiesEnabled` + starts a `for await tokenData in activity.pushTokenUpdates` listener that POSTs each token to backend. `endIfStale()` 2-phase 10-min latch (foreground call after `inProgress == 0` arms `allDoneAt`, second call ≥600s later ends the Activity + tells backend to drop the token, any item flipping back to in-flight resets the latch). Bearer comes from `KeychainStore.load()?.sessionToken` directly — decoupled from `AppState` because `pushTokenUpdates` can deliver outside the SwiftUI view tree.
- **Triggers**: `ImportViewModel.pushToDesktop` fires `ensureActivity(...)` AFTER successful `enqueueImport`, BEFORE `state = .pushedToDesktop`; foreground `scenePhase == .active` fires `endIfStale()` from `WhatsubMobileApp.ContentView`. Both gated `if #available(iOS 16.2, *)` because app deployment target is still 16.0.
- **Deep links**: `whatsub://import-queue` → switches to MeView tab + binds `appState.meShowImportQueue = true` (drives the existing NavigationLink to `ImportQueueView`). `whatsub://library` → switches to Library tab. Selected tab lifted from `ContentView` `@State` to `AppState.selectedTab` so the URL handler can drive it.
- **Widget UI**: `whatsub-widget/LockScreenCard.swift` (icon + title + 3 stat blocks + 最近: line) + `whatsub-widget/ImportActivityWidget.swift` (`ActivityConfiguration` with Dynamic Island regions + smart `widgetURL` routing — `whatsub://import-queue` while in-flight, `whatsub://library` once all done).
- **Entitlements**: main app gains `aps-environment: development` in `project.yml`. Apple auto-swaps to `production` for App Store distribution builds.

**Critical APNs JWT gotcha**: `signer.sign({key, dsaEncoding: 'ieee-p1363'})` is required — Node's `createSign('SHA256').sign(key)` default is DER-encoded ASN.1 which Apple rejects with `InvalidProviderToken`. The `'ieee-p1363'` encoding produces the raw 64-byte r||s signature Apple expects. Critical to document inline so future maintainers don't "simplify" it.

**iOS 16.1 vs 16.2**: ActivityKit shipped on 16.1 but `Activity.request(attributes:content:pushType:)` + `ActivityContent` + `Activity.end(_:dismissalPolicy:)` are 16.2 only — earlier 16.1 used a different request shape (deprecated immediately in 16.2). Targeting 16.2 lets us use the modern ContentState + push.token path the rest of the coordinator depends on. Coverage is still ~97% of devices in mid-2026.

**Phase 0 manual steps**: APNs Auth Key creation at developer.apple.com (one .p8 download, save Key ID + paste contents into GitHub Secrets `APNS_KEY_ID` + `APNS_KEY_P8` + `APNS_TEAM_ID=Q3BK52FQT9`); Aliyun `/opt/whatsub/.env` gains the matching vars (the `environment:` block in `docker-compose.yml` is already wired in `b4f54f1`); `docker compose up -d --force-recreate whatsub-license` on Aliyun once the env is in place. Without the env vars the helper silently no-ops (logs `[apnsPush] missing env, skipping push`) — useful for local dev where APNs isn't set up.

### iOS Native YouTube Caption Extraction via Innertube (2026-06-19)

Replaces the legacy WKWebView + fetchHook path (~30% success rate
against BotGuard) with a pure-Swift HTTP client that calls YouTube's
Innertube `/v1/player` API claiming to be `ANDROID_TESTSUITE` — the
same trick yt-dlp's `--extractor-args "youtube:player_client=android"`
and NewPipe use. YouTube serves Android-claiming clients via a
different API path with no BotGuard / no PO_TOKEN / no signature
deobfuscation, because Android native apps can't run JS sandboxes
and YouTube can't enforce device attestation across the broader
Android ecosystem without breaking smart TVs / Roku / Apple TV.

Architecture: `Import/YouTubeCaptionExtractor.swift` (~150 LoC) makes
two HTTP calls (POST player API → GET timedtext + fmt=json3), reuses
`parseTimedtextJson3`, and writes a permanent per-video disk cache at
`Caches/yt_captions/<videoId>.json` via `Import/CaptionCache.swift`
(~50 LoC). Spec: `docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md`.

Net change: −400 LoC. Deleted `CaptionExtractor.swift`,
`CaptionHookJS.swift`, `WKWebViewHost.swift`. UI simplified —
`.extracting` body is now a centred spinner instead of a 320×180
visible WebView. Diagnostics surface (`CaptionDiagnosticsSheet`)
unchanged; receives progress events via the new extractor's
`onProgress` callback.

Risk horizon: ANDROID_TESTSUITE may require PO_TOKEN within 1-2
years. Mitigation: switch the `clientName` constant to
`TV_EMBEDDED` and the `X-YouTube-Client-Name` header to `85` — TV
clients have minimal anti-scraping for ecosystem-compatibility
reasons. If that also locks: backend yt-dlp service (architecturally
designed earlier; unbuilt by choice — keeps server costs flat).

**2026-06-20 update**: ANDROID_TESTSUITE got fully removed from yt-dlp's `INNERTUBE_CLIENTS` dict late 2024; YouTube progressively tightened it through 2026. We migrated to a 4-client fallback chain that mirrors yt-dlp's 2026 defaults: `ANDROID_VR` (Oculus Quest YouTube VR app — primary, no PO_TOKEN) → `TVHTML5_SIMPLY_EMBEDDED_PLAYER` (best at age-gate / kids-mode bypass) → `IOS` (clientVersion 21.02.3 / iPhone16,2 / iOS 18.2 — bumped from stale 19.x metadata that started returning HTTP 400) → `MWEB` (mobile-web safety net). The chain catches **all** `CaptionError` types (HTTP 4xx, URLError, parse), not just status-based `UNPLAYABLE` / `LOGIN_REQUIRED` — earlier transport-error logic propagated out before subsequent clients could try. Status-based exhaustion still takes precedence over transport-error exhaustion when both occur (more accurate UX). When YouTube changes anything next, mirror `yt-dlp/yt_dlp/extractor/youtube/_base.py` `INNERTUBE_CLIENTS` constants.

### Streaming LLM analysis + JsonLineParser (DeepSeek v4, 2026-06-21)

Mirror of desktop `Get_Video/client/src/llm/analyze.ts` + `streamingJson.ts`. **Why**: `deepseek-chat` + `deepseek-reasoner` retire 2026-07-24; V4 replacements (`deepseek-v4-flash` / `deepseek-v4-pro`) emit long JSONL outputs that overflow non-stream `max_tokens=4096` and put substantial content in `reasoning_content` for long batches.

Three pieces:
- **`JsonLineParser.swift`** — buffers SSE text chunks, splits on `\n`, fires handler per complete `{...}` line. Tolerates prose interleaved with JSONL (DeepSeek BYOK occasionally narrates "Now emitting next cue:" between objects).
- **`ChatCompletionsClient.streamChat`** — real `URLSession.bytes(for:) + .lines` over SSE. Yields `delta.content` (preferred) or `delta.reasoning_content` (v4 fallback). `max_tokens=16384` + 300s timeout uncaps batch length.
- **`AnalysisEngine.analyze`** — streams batches through `JsonLineParser` → `parseCue(obj:)` / `parseSummary(obj:)`. Progress ticks per-cue (was per-batch) for a smooth UI. Summary failure keeps the per-cue results.

Trade-off: chat-style single-shot calls (QuickChat, CollectSheet, Roleplay, Photo) still use the simpler non-streaming `chat()` — only AnalysisEngine wants per-line incremental delivery.

### Import flow auto-sync (2026-06-21)

After streaming LLM landed, the captionsReady preview stage + "同步到云库" confirmation button both turned out to be friction without value. New flow:

```
粘 URL → 「手机解析」 → extract → analyze (streaming + ETA) → sync → done
```

Zero user confirmation between stages. `ImportViewModel.run(urlOrId:, token:, email:)` threads the token through so it can chain into `sync()` without bouncing back to the View. `state = .analyzing(done, total, cueCount)` carries cueCount so the UI renders "预计约 N 秒 / N 分钟" alongside the live bar (heuristic ~1s/cue + 5s phase-2 floor at 30s). Error path: `.error` screen surfaces a「重试 AI 解析」button that calls `retryAnalysisOnly(token:)` — skips re-extract because rawCues stay in memory (and disk cache).

### VPN routing UX (Chinese users, 2026-06-21)

iOS can't bypass system VPN per-request (no public API — `URLSessionConfiguration.connectionProxyDictionary` only covers HTTP proxies, not packet tunnels). When user's VPN routes `whatsub.eversay.cc` through HK exit → TLS -1200. Two pieces:

- **`VPNRuleHelpSheet.swift`** — one-screen sheet with copy-button rule snippets for Clash/Stash/Mihomo + Shadowrocket + Surge + Quantumult X + Loon (>95% of CN power-user base). The single durable fix is `DOMAIN-SUFFIX,eversay.cc,DIRECT` in the user's VPN app — adds eversay.cc to the direct-connect rule, YouTube still routes via VPN. BYOK users (who hit their LLM vendor directly) get a separate one-line hint pointing at their own LLM settings.
- **`RelayLoadingView.swift`** — 5s stall hint. Normal spinner + label first; after 5s without progress flips to a yellow shield icon + "可能 VPN 拦了 eversay.cc" copy + 「查看 VPN 直连规则」 button. No active probe of eversay.cc — the real network call IS the probe. Wired into Library 详情→收藏 tab (`EntryCollectionsList`) and Library 详情→角色扮演 tab (`RoleplayTabView`).

Plus a BYOK-shadowed-by-relay warning in `LlmSettingsView` (yellow Section + one-tap "关掉托管" button): user fills BYOK fields but forgets to flip the relay toggle off → settings are persisted but `ChatCompletionsClient.resolveConfig()` ignores them. Without the banner the only signal was the error host showing `eversay.cc` instead of the BYOK vendor.

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

- **App Store 公开上架后,**`MARKETING_VERSION`** 那个「train」被 Apple 锁,继续传同版本号 TestFlight 报 409.** 2026-06-17 撞的：连续 3 次 TestFlight 跪,`xcrun altool` 报 `Invalid Pre-Release Train. The train version '0.0.1' is closed for new build submissions` + `CFBundleShortVersionString [0.0.1] must contain a higher version than the previously approved [0.0.1]`。触发条件: 当前 binary 的 `CFBundleShortVersionString` 跟已上架的相同。Fix: `project.yml` 里 `MARKETING_VERSION` bump 到下一版(e.g. 0.0.1 → 1.0.0 或 0.0.2),重 push 即可。**注意**：build number (`CURRENT_PROJECT_VERSION` / CI 的 `BUILD_NUM`) 自增解的是「同 marketing version 下 build 号不能重复」,跟 train 锁是两件事 — TestFlight 已用过的 build 号继续传只会让 build 号冲突,不会绕过 train 锁。每次给已上架版本发 hotfix 都得 bump marketing version。

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

- **`TextField(axis: .vertical)` 不能用回车收键盘 — 必须显式加 `.toolbar(.keyboard)` Done 按钮.** 2026-06-21 字幕编辑撞的：单行 `TextField` 回车会触发 `onSubmit` 默认收键盘，但 `axis: .vertical` 把回车当换行插入,用户根本没法收键盘。模板: `@FocusState private var focused: Bool` + `.focused($focused)` 绑 textfield + `.toolbar { if focused { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focused = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } } } }`。`sendAction` 是 belt-and-suspenders（per [[feedback_keyboard]] memo：`@FocusState` 偶尔跟实际键盘状态脱节）。代码模板看 `CueRowEditing.swift`。

- **Swift `Result<Success, Failure>` requires `Failure: Error` — `Result<[T], String>` is a compile error.** Symptom (build 247): `'String' does not conform to protocol 'Error'` 1m57s into CI on a `RoleplayScenarioClient` that wanted to surface human-readable failure messages via the `Result` API. There's no clean way to make `String` conform retroactively. Fix: define a tiny custom enum (`enum DerivationOutcome { case success([T]); case failure(String) }`) — it keeps the string channel the UI banner wants without inventing a one-case error type that'd add zero value. Existing switch-on-result call sites are binary-compatible since case names match.

- **Refactoring `Networking/DTOs.swift` breaks the test target silently — `@testable import` exposes the same DTOs to both sides.** Hit 3× in one push cycle on 2026-06-03 while shipping the per-video roleplay feature (Stage 2 added `libraryEntryId/youtubeId` to `CorpusSource` + made `url` Optional; `PhraseSelectorTests.swift` and `CorpusDecodeTests.swift` both still used the old init / forced non-Optional unwrap → 3 sequential CI failures, ~30 min wasted + 3 cert touches). Before pushing a DTO change: `grep -rn "CorpusSource(\|MineItem(\|\\.source\\.url\\b" whatsub-mobileTests` — explicit init call-sites need the new field (nil is fine), force-unwrap rotted-Optional fixtures with `!` rather than `?? ""` so a regressed fixture screams instead of silently degrading.

- **`SwiftUI.AsyncImage` 一旦 `.failure` 就永不重试 + `URLCache.shared` 可能缓存失败响应 → 网络抖动后图片永久跪.** 2026-06-17 build 上撞的：用户开 VPN 看 YouTube,回 Library 列表本应免 VPN 的 OSS 封面（`whatsub.eversay.cc/api/library/thumb/<id>`）全显占位 icon；关 VPN 下拉刷新数据回来了封面照样跪,杀进程才恢复。两层叠加：(1) AsyncImage 按 URL identity 缓存 phase,URL 不变就不重发请求,且无重试 API 暴露；(2) URLCache 可能把失败响应持久化,关 VPN 后 URLSession 直接返缓存。修复：自写 `Components/RemoteImage.swift`,`URLRequest(cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)` + `.task(id: (url, externalNonce, manualRetry))` 让父 VM 自增 nonce 触发 refetch + 失败可点击重试 + `URLError` 类错误自动延迟 1.2s 重试 1 次。**通用经验**：国内 + VPN 用户场景下任何非 100% 高可用图片源(自家后端/海外 CDN)都别直接用 stock AsyncImage,从一开始就 RemoteImage。

- **Absolute dBFS VAD thresholds don't survive real-world ambient noise.** Symptom (builds 226-232 of QuickChat): orb stuck in "listening" indefinitely after the user finished talking. Root cause: AVAudioRecorder's `averagePower` for the silence test was -40 dBFS (then -34 in build 230), but typical rooms sit at -35 to -28 dBFS (fans/AC/traffic). `silentSinceMs` never accumulated → only the 12 s hard cap saved us. **Fix in `VoiceActivityRecorder.swift`**: switched to `AVAudioEngine` input tap so we get raw audio buffers + dual-signal end-of-turn detection: (A) **relative dB** — track peak dBFS since onset, use `max(peak - 15 dB, -38 dB floor)` as the silence gate so the threshold adapts to the user's voice envelope; (B) **live ASR partial-result stability** — feed the same tap buffers into `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true`, end the turn if the partial transcript hasn't changed for 1.2 s AND we have at least one word (this is what Siri's endpointer does internally). Either signal can end the turn; whichever fires first wins. As a side benefit the live transcript is returned via `onSpeechEnded` directly so the post-recording `SFSpeechURLRecognitionRequest` call in `QuickChatView.handleVADSpeechEnded` is gone.

### Share-to-import + Share Extension

- **WKWebView 默认 iOS UA 让 YouTube serve「mobile-web 降级播放器」,timedtext 接口悄悄迁到 `youtubei.googleapis.com/v1/player`,我们的 `/api/timedtext` 老路径 hook 全失效.** 2026-06-17 撞的回归：`CaptionExtractor` 突然 25s 超时全错,同一份 fetchHook.js 在浏览器插件里照常工作。代码 4 个月没动,纯属 YouTube 2025-2026 期间逐步收紧 mobile-web 反爬。修复在 `CaptionExtractor.swift` 加 `web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ... Chrome/130.0.0.0 ..."` 装桌面 Chrome → YT 给桌面播放器代码 + 老路径,跟插件环境一致；同时 `CaptionHookJS` 拓宽 URL 匹配到 `youtubei/v1/player` 响应里 parse 出 `captionTracks[].baseUrl` 主动 fetch,作为 belt-and-suspenders。**通用经验**：任何嵌第三方 SPA(YouTube / B 站 / Twitter…)的 WKWebView 都该一开就把 UA 钉死成桌面 Chrome 主流 build,否则功能跟着对方移动端策略调整一起**静默跪**——没 4xx、没 Sentry、就是事件不再触发。

- **(SUPERSEDED 2026-06-19 by Innertube path — see «iOS Native YouTube Caption Extraction via Innertube» above.)** Historical: YouTube timedtext required a `po_token` (anti-scrape, 2024) on the **web client** path, so URLSession `GET /api/timedtext` always returned 403. The original workaround was to inject a MAIN-world fetch hook (`fetchHook.js`) into a WKWebView running the real YouTube player and intercept the player's own already-signed timedtext request via `WKScriptMessageHandler`. The "no clean URLSession path" conclusion turned out to be wrong: calling Innertube `/v1/player` while claiming to be `ANDROID_TESTSUITE` bypasses BotGuard + PO_TOKEN entirely, since Android native clients can't be JS-attested. Kept here as a record of the failed assumption.

- **Share Extension is a separate target + separate bundle ID + App Group.** The extension (`cc.eversay.whatsub.mobile.share`) and the main app (`cc.eversay.whatsub.mobile`) share the `group.cc.eversay.whatsub.mobile` App Group entitlement. Both targets must have this entitlement, both must be registered in the Apple Developer portal (App Groups capability), and the provisioning profiles for BOTH must include the capability — otherwise the extension silently fails to read/write the shared UserDefaults. `AppGroup.swift` is compiled into both targets (listed in `project.yml` under both `sources`).

- **Share extension that opens a deep-link can lock up the host app's UI on return (YouTube ~30s frozen).** 2026-06-19 撞的: 从 YouTube 分享到 whatSub → whatSub 打开 → 用户返回 YouTube → YouTube 不响应任何触摸,等 ~30s iOS GC 掉 orphan view 才恢复。三个叠加因素,缺一不可: (1) `viewDidLoad` 太早就发起 `extensionContext.open(url)` — extension VC 还没 present 完,host app 拿回前台时我们的(透明) view 还挂着吃触摸。改成 `viewDidAppear` 等 present 完才发。(2) `extensionContext.completeRequest(returningItems: nil)` 无 completion handler — iOS 不等 view 拆完就 resume host app。改成 `completeRequest(...) { _ in ... }` + `withCheckedContinuation`。(3) responder-chain `perform("openURL:")` fallback hack — 在 iOS 14+ 已经不需要(ctx.open 全平台稳),留着只会戳到 host app 的 responder 状态,是 YouTube freeze 的主嫌疑。直接删,改靠 AppGroup + main app scenePhase safety-net 兜底。模板看 `whatsub-share/ShareViewController.swift`。

- **`NSSupportsLiveActivities` 是 Live Activity / 灵动岛功能的「准入证」,没声明 iOS 静默不显示。** 2026-06-19 build 232+ Live Activity 整套 APNs/coordinator/widget chain 跑得好好的,但锁屏和灵动岛永远空白 —— 因为 `whatsub-mobile/Info.plist` 漏了 `NSSupportsLiveActivities=YES`。Apple 把这当成 capability declaration,没声明就 silently 拒绝每个 `Activity.request(...)` 调用 (no error, no console log, no token delivery)。**通用经验**: 任何用 ActivityKit 的功能,Phase 0 入口的第一行 checklist 就该是「Info.plist 里加 `NSSupportsLiveActivities: true`」。我们之前 plan Phase 0.2 只加了 `aps-environment` entitlement(APNs push 用),把 capability declaration 忘了。`project.yml` 用 `info.properties.NSSupportsLiveActivities: true` 落地。

- **DeepSeek v4 reasoning 模型把答案放 `reasoning_content`, `content` 是 ""; `??` nil-coalesce 不触发.** 2026-06-21 用户切到自配 `deepseek-v4-flash` 报「服务返回错误 200」, response body 里 `content:""` + `reasoning_content:"We need to output one JSON line per cue..."`。`deepseek-chat` 和 `deepseek-reasoner` 2026-07-24 下架,只能用 v4 系列。我们原 parser `let c = msg["content"] as? String ?? msg["reasoning_content"]` 是 no-op —— `""` 非 nil,`??` 不触发。**修复**: 先 trim `content`,trim 后为空才 fallback 到 `reasoning_content`。**但真正根治是改流式** —— v4 batch 输出 8-15K token 一次性 fetch 撑爆 4096 max_tokens；流式不限长 + 边收边 parse JSONL。模板看 `ChatCompletionsClient.streamChat` + `JsonLineParser.swift` + `AnalysisEngine.analyze`（mirror 桌面 `analyze.ts` + `streamingJson.ts`）。

- **iOS YouTube Innertube fallback chain: 区分"状态码 OK 但视频不可播" vs "transport 错"。** 2026-06-20 撞的: `X_-Q1hOYeCo` 这种视频 ANDROID_TESTSUITE 返 UNPLAYABLE → 试 IOS 返 HTTP 400 → fallback chain 直接抛错,根本没试到 TVHTML5。**原因**: 早期版本的 chain 只在 200 + UNPLAYABLE/LOGIN_REQUIRED 这种 status 错误上 continue,transport 层(HTTP 4xx / URLError / parse error)的 throw 会直接 propagate 出循环。**修复**: catch CaptionError → log → 记下 lastError → continue;只有所有 client 都失败时才抛 lastError(status-based exhaustion 优先于 transport-error exhaustion,UX 更准)。**附带教训**: chain 顺序也得调,2026 年 IOS client 比 TVHTML5 更容易被 YouTube 拒(因为 Apple 平台是 YouTube 的可控生态)。当前正确顺序: ANDROID_TESTSUITE → TVHTML5 → IOS。IOS client metadata 也得跟上 yt-dlp 当前版本(19.45.4 / iPhone16,2 / iOS 18.1.x),老的 19.09.x + iPhone14,3 现在直接被拒 HTTP 400。

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
