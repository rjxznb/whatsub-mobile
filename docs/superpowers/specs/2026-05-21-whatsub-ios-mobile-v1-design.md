# whatSub iOS Mobile v1 — Design Spec

**日期**: 2026-05-21
**作者**: Claude（与 @rjxznb 共同设计）
**状态**: Draft（待 owner 确认）
**目标**: 在 iOS 上发布 whatSub 的消费端 app，TestFlight 内测可装

---

## 1. 概述

whatSub 现有三件套产物：浏览器扩展（划词收藏 + YouTube 双语字幕）、桌面客户端（Tauri 2，做 yt-dlp + whisper + LLM 解析）、后端（Hono + Postgres，做激活 / 支付 / 公共语料库）。**iOS v1 是消费端**：用户在桌面上把视频解析好以后，能在手机上随时打开、看双语字幕跟读、查公共/私人语料库。

**核心使用场景**：
1. 通勤 / 床上拿着手机翻语料库（公共 + 私人）+ 看带嵌入 YouTube 的例句
2. 桌面端解析完一个视频 → 点同步 → 手机 / Mac TestFlight 上立刻能拉这个条目看双语字幕跟读

**不在 v1 的事情**（用户已确认是"消费性"）：
- 划词收藏 / 贡献到语料库（iOS 端只读）
- 词汇本同步（v2）
- Bilibili / 本地视频源（v1 仅 YouTube）
- 字幕样式自定义（v1 用合理默认）
- 通过分享导入 YouTube URL + LLM 解析（**v1.5**：用户自带 LLM key、自动同步进 library）
- AirPlay / 画中画 / 离线下载 / 推送通知 / Sign in with Apple

**截止线**: TestFlight Internal Testing 可用版本。App Store 正式上架留到 v2（v1 走完后定时间窗）。

---

## 2. 系统架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│  whatSub iOS app（新工程 rjxznb/whatsub-mobile）                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  SwiftUI · iOS 16+ · 3-tab TabView                                │   │
│  │    Tab 1: 语料库（公共 + 我的，tag 多选 AND 筛选）                │   │
│  │    Tab 2: Library（云同步过的 YouTube 条目，双语字幕跟读）         │   │
│  │    Tab 3: 我的（账号 / license 状态 / 退出）                       │   │
│  │  YouTube 嵌入：WKWebView + IFrame Player API + JS 双向 bridge      │   │
│  │  Session：Keychain（30 天有效，sessionToken）                      │   │
│  └────────────────────────┬─────────────────────────────────────────┘   │
└────────────────────────────┼─────────────────────────────────────────────┘
                             │ HTTPS, Bearer auth
              ┌──────────────┴──────────────────┐
              ▼                                 ▼
   ┌──────────────────────┐         ┌──────────────────────┐
   │ /api/auth/*          │         │ /api/library/* 【新】 │
   │ /api/corpus/*        │         │  POST  /sync          │
   │ （都已存在）          │         │  DEL   /sync/:id      │
   │                      │         │  GET   /list          │
   │                      │         │  GET   /entry/:id     │
   └──────────┬───────────┘         └──────────┬───────────┘
              └──────────────┬─────────────────┘
                             ▼
              ┌────────────────────────────────────┐
              │ whatsub-license backend (Hono)     │
              │ Postgres library_entries 新表       │
              └────────────────┬───────────────────┘
                               ▲
                               │ 桌面 reqwest POST/DEL
              ┌────────────────┴───────────────────┐
              │ 桌面客户端（Get_Video/client）       │
              │  Library 卡片新增 ☁️ 同步按钮       │
              │  Library 页顶「云同步详情」入口     │
              │  Rust commands: library_sync.rs    │
              │  library.json schema 加 syncedAt   │
              └────────────────────────────────────┘
```

**关键 invariant**：library 数据所有权按 `owner_email` 分区。桌面 push 时 session 决定 owner_email；iOS pull 时同理。**两端必须用同一邮箱登录**才能看到对方同步过的内容。

---

## 3. 后端改动（whatsub-license）

### 3.1 新表

```sql
CREATE TABLE IF NOT EXISTS library_entries (
  id TEXT PRIMARY KEY,                       -- 复用桌面 library video_id
  owner_email TEXT NOT NULL,                  -- 从 session 解出
  youtube_id TEXT NOT NULL,                   -- v1 仅 YouTube
  source_url TEXT NOT NULL,
  title TEXT NOT NULL,
  duration_sec INTEGER,
  thumb_url TEXT,                             -- https://i.ytimg.com/vi/{yt}/mqdefault.jpg
  transcript_srt TEXT NOT NULL,               -- ~10-50 KB
  analysis_json JSONB NOT NULL,               -- ~50-300 KB（cues + highlights + summary）
  storage_location TEXT NOT NULL DEFAULT 'inline',  -- 'inline' | 'oss'（v2 预留）
  synced_at BIGINT NOT NULL                   -- unix ms
);
CREATE INDEX IF NOT EXISTS idx_library_owner ON library_entries(owner_email, synced_at DESC);
CREATE INDEX IF NOT EXISTS idx_library_owner_yt ON library_entries(owner_email, youtube_id);
```

**存储决策**：v1 全部存 Postgres TEXT/JSONB 列（TOAST 自动处理大字段）。至 30 GB 量级前不切 OSS。`storage_location` 字段为未来 OSS 迁移预留 hint，目前永远写 `inline`。

### 3.2 新增 4 个 endpoints

所有路径走 Bearer session auth（**不**额外加 license 门槛——library 是用户自有数据，所有权由 email 决定）。

| 方法 | 路径 | 调用方 | 行为 |
|---|---|---|---|
| POST | `/api/library/sync` | 桌面 | upsert 一条（`id` 冲突就更新所有字段 + `synced_at = now`） |
| DELETE | `/api/library/sync/:id` | 桌面 | 双键校验 `owner_email + id` 后 DELETE |
| GET | `/api/library/list` | iOS | 返回**轻量列表**`[{id, youtube_id, source_url, title, duration_sec, thumb_url, synced_at}]`，不含大字段；`source_url` 留给 iOS 在「打开 YouTube app」时复用原始 URL 还原 `&t=NN` 时间戳 |
| GET | `/api/library/entry/:id` | iOS | 返回完整一条（含 transcript_srt + analysis_json） |

**轻量列表 vs 全量**：列表 1000 条仍 < 1 MB 流量，详情按需拉。

### 3.3 代码结构

- `src/routes/library.ts`（新文件 ~150 行）
- `src/lib/db.ts` 加 4 个方法：`upsertLibraryEntry / deleteLibraryEntry / listLibraryEntriesForOwner / getLibraryEntry`
- `src/lib/types.ts` 加 `LibraryEntryRow / LibraryEntryListItem`
- `src/index.ts` 注册新路由

### 3.4 测试

`tests/library.test.ts` 用 pg-mem 覆盖：
- happy path: 桌面 POST sync → iOS GET list 命中 → iOS GET entry 命中
- 跨用户隔离: A 的 token 不能 GET B 的 entry，list 不出现 B 的
- 跨用户删除拒绝: A 的 token DELETE B 的 id 返 404
- upsert: 同 id 重复 POST 只更新 `synced_at` + 字段
- 401: 无 token / token 过期都返 401
- 大字段: 200 KB analysis_json round-trip 完整

### 3.5 部署

1. 改 schema.sql → scp → `docker exec enghub-postgres-1 psql ... < schema.sql`（IF NOT EXISTS 幂等）
2. `docker buildx build --load` → docker save → scp → docker load → `docker compose up -d --force-recreate`
3. smoke：用一个测试 session token 跑一遍 POST / GET / DELETE 链

**工作量**：1 天（含写 + 测 + 部署）。

---

## 4. 桌面客户端改动（Get_Video/client）

### 4.1 Library 卡片同步按钮（`pages/Library.tsx`）

每张 LibraryCard 右上角加 ☁️ 图标按钮。**仅 YouTube 源**可点：

| 状态 | 图标 | 行为 |
|---|---|---|
| 未同步 | ☁️ 灰 | 点击 → 弹「同步到云？仅字幕 + 元数据，不上传视频文件」 |
| 同步中 | ⏳ 转 | 不可点 |
| 已同步 | ✅ 绿 | 点击 → 弹「已在云端 · 同步时间 X 分钟前」+ 操作菜单 |
| 失败 | ✗ 红 | 点击 → 显示 `friendlyNetworkMessage` 错误 + 重试 |

非 YouTube 源（Bilibili / 本地）按钮 disabled + tooltip：「v1 仅 YouTube 源支持云同步」。

### 4.2 library.json 增量 schema

```ts
interface LibraryEntry {
  // ... 原有字段
  syncedAt?: number;        // unix ms，已同步过；从云删除后清空
  syncError?: string;       // 上次同步失败原因
}
```

`mergeWithDefaults` 已处理向后兼容。

### 4.3 删除条目联动

已同步条目执行删除时弹 modal：

```
这个条目已同步到云（iOS 可见）。

  ◉ 同步从云上 / iOS 删除（推荐）
  ○ 仅删除本地，云端保留

  [ 取消 ]  [ 删除 ]
```

未同步条目维持原 UX。

### 4.4 Library 页顶部「云同步详情」入口

Library 顶部加按钮 → 打开 dialog/页面列出当前 email 下所有云上条目：
- 缩略图 + 标题 + 同步时间 + 「从云下架」按钮
- 顶部「全部下架」批量操作
- 用途：孤儿条目清理（本地已删但云端未下架）

### 4.5 Rust commands（新文件 `src-tauri/src/commands/library_sync.rs`）

```rust
#[tauri::command]
pub async fn library_sync_to_cloud(id: String) -> Result<(), String>;

#[tauri::command]
pub async fn library_unsync_from_cloud(id: String) -> Result<(), String>;

#[tauri::command]
pub async fn library_list_synced() -> Result<Vec<LibraryListItem>, String>;
```

HTTP 走 `reqwest`（**不**走 WebView fetch，复用 `commands/license.rs` 模式），30s timeout，错误前缀化（`timeout:` / `connect:` / `tls:` / `http <N>:`）。

### 4.6 前置校验

`library_sync_to_cloud` 校验：
- entry.status === "completed"（中途暂停不行）
- entry.sourceType === "youtube"
- analysis.json + transcript.srt 文件都存在
- session token 有效（无效就提示「请回主界面确认登录状态」）

**工作量**：1.5 天（含 UI + Rust + tests）。

---

## 5. iOS app 设计

### 5.1 工程配置

| 项 | 值 |
|---|---|
| 项目名 | `whatsub-mobile` |
| Bundle ID | `cc.eversay.whatsub.mobile` |
| iOS 最低版本 | 16.0 |
| UI 框架 | SwiftUI（仅 YouTube 嵌入用 UIViewRepresentable 包 WKWebView） |
| 架构 | MVVM-lite（ObservableObject + async/await） |
| 包管理 | Swift Package Manager |
| 第三方依赖 | **0 个**（dev only: SwiftLint） |
| 语言 | 仅中文 hardcoded |
| 主题 | 跟随系统深/浅色 + brand `#3B9BFF` accent + `#FCD34D` highlight |

### 5.2 顶层导航

`TabView` 三个 tab：
- 📚 **语料库**（默认）
- 🎬 **Library**
- 👤 **我的**

未登录时整个 app 上盖 modal `AuthGateView`（不可绕过）。

### 5.3 核心 View 与职责

| View | 内容 |
|---|---|
| `AuthGateView` | 邮箱表单 → POST `/api/auth/send-code` → 6 位 OTP → POST `/api/auth/verify-code` → 拿 sessionToken 存 Keychain → 关闭 modal |
| `CorpusView` | 顶部 `Picker(.segmented)` 公共/我的，下方 `TagChipRow`（横滑、多选 AND），主体 `List` 短语行（短语 + 释义 + 内联 tag chips）。Pull-to-refresh。 |
| `PhraseDetailView` | 短语 + 释义 + 笔记；sticky `YouTubeEmbedView`；公共/我的例句出处列表，每条 ▶ MM:SS。点 ▶ 触发 seek（更新 SeekTrigger nonce）。 |
| `LibraryView` | List + 缩略图 + 标题 + 时长徽章。Pull-to-refresh。 |
| `LibraryDetailView` | **竖屏**: 上半 YouTube + 下半字幕（推荐）。**横屏**: 字幕作为 overlay 盖在 YouTube 下方。靠 `@Environment(\.verticalSizeClass)` 切布局。 |
| `MeView` | 邮箱 + license 徽章（有效绿 / 无灰）+ 「去网站购买」按钮（未购）→ 跳 Safari `whatsub.eversay.cc/#pricing` + 退出 + 关于 + 版本号 |

### 5.4 字幕渲染（LibraryDetailView 下半区）

- `SRTParser` 把 transcript_srt 解成 `[Cue(index, startSec, endSec, englishText)]`
- 合并 `analysis_json` 每个 cue 的 `chineseTranslation` + `highlights: [{text, meaning_zh, ipa?, usage_note?}]`
- 渲染：`ScrollViewReader` + `LazyVStack`，每个 cue 一个 `CueView`
  - 英文行：`Text` 22pt + `AttributedString` 在 highlight 词上加黄色下划线 + tap gesture
  - 中文行：`Text` 16pt 灰色（`.secondary`）
- 跟随播放：YouTube bridge 每 250ms 传 currentTime → 算当前 cue → `withAnimation { proxy.scrollTo(currentCue, anchor: .center) }`
- 点 cue → seek
- 点 highlight 词 → 弹 popup（释义 + IPA + 「看详情」按钮跳 PhraseDetailView，用 `phrase = highlight.text` 查 `/api/corpus/lookup`）

### 5.5 YouTube 嵌入（`YouTubeEmbedView`）

```swift
struct YouTubeEmbedView: UIViewRepresentable {
    let videoId: String
    @Binding var seekTrigger: SeekRequest?    // (sec, nonce)
    var onTimeUpdate: (Double) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "iosBridge")
        let webView = WKWebView(frame: .zero, configuration: config)
        // 加载本地 HTML：
        //   <html><body><div id="player"></div>
        //   <script src="https://www.youtube.com/iframe_api"></script>
        //   <script>
        //     var player; function onYouTubeIframeAPIReady() {
        //       player = new YT.Player('player', {
        //         videoId: '\(videoId)', host: 'https://www.youtube-nocookie.com',
        //         playerVars: { playsinline: 1, modestbranding: 1 },
        //         events: { onReady, onStateChange }
        //       });
        //       setInterval(() => {
        //         if (player.getCurrentTime) {
        //           window.webkit.messageHandlers.iosBridge.postMessage(
        //             { type: 'time', sec: player.getCurrentTime() });
        //         }
        //       }, 250);
        //     }
        //   </script></body></html>
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let req = seekTrigger {
            webView.evaluateJavaScript("player.seekTo(\(req.sec), true); player.playVideo();")
        }
    }
}
```

**为什么不用 youtube-ios-player-helper**：维护半停摆、官方建议用 IFrame API 原生集成。我们的实现 ~80 行 Swift，0 依赖。

### 5.6 网络层（`actor WhatsubAPI`）

- 单一 `URLSession`，async/await
- `enum APIError: network | unauthorized | server(Int, String?) | decoding(Error)`，UI 翻译成中文
- 401 自动登出 → 清 Keychain → re-show AuthGateView
- 所有非 auth 请求 attach `Authorization: Bearer <token>`

Endpoints：
```
POST /api/auth/send-code      { email }
POST /api/auth/verify-code    { email, code } → { sessionToken, expiresAt }
GET  /api/auth/me             → { email, hasActiveLicense }
POST /api/auth/logout
GET  /api/corpus/tags?scope=public|mine
GET  /api/corpus/browse?tags=a,b,...
GET  /api/corpus/mine?tags=a,b,...
GET  /api/corpus/lookup?phrase=X&withScope=true
GET  /api/library/list
GET  /api/library/entry/:id
```

### 5.7 Keychain session（`enum KeychainStore`）

- `kSecClassGenericPassword` with `service = "cc.eversay.whatsub.mobile.session"`
- accessibility = `kSecAttrAccessibleAfterFirstUnlock`（解锁过一次就能用）
- 存 `Session { email, sessionToken, expiresAt }`

### 5.8 工程目录

```
whatsub-mobile.xcodeproj
whatsub-mobile/
├── App/              WhatsubMobileApp.swift / AppState / Theme
├── Auth/             AuthGateView / AuthViewModel / KeychainStore
├── Corpus/           CorpusView / PhraseDetailView + VMs
├── Library/          LibraryView / LibraryDetailView + SubtitleScrollView
├── Me/               MeView
├── Components/       YouTubeEmbedView / TagChipRow / PhraseRow
├── Networking/       WhatsubAPI / Endpoints / DTOs
├── Models/           Phrase / Cue / LibraryEntry / Session
├── Utilities/        SRTParser / DateFormatters
└── Assets.xcassets   Colors + AppIcon
whatsub-mobileTests/    SRTParser + WhatsubAPI mock + SubtitleHighlight
whatsub-mobileUITests/  CI 截图测试目标
```

**工作量**：18-22 天纯写代码。

---

## 6. CI / TestFlight / 截图反馈

### 6.1 新仓 + 三个 workflow

仓: `rjxznb/whatsub-mobile`（private）。

#### `ci.yml` — push 触发
```
on: [push, pull_request]
runs-on: macos-14
steps:
  - SwiftLint
  - xcodebuild test (单元测试)
  - xcodebuild build for iOS Simulator
  - simctl boot 'iPhone 15 Pro'
  - 跑 UI 测试目标的 ScreenshotTests
  - 每个状态截图 → upload-artifact
  - PR comment 嵌入截图链接
```
预算: ~6-8 min/次（weighted 60-80 min）。

#### `testflight.yml` — main 分支 / tag 触发
```
on:
  push:
    branches: [main]
    tags: ['v*']
runs-on: macos-14
steps:
  - 写 .p8 (从 secret 解出)
  - bump build number = run_number
  - xcodebuild archive -allowProvisioningUpdates \
      -authenticationKeyID $KEY_ID \
      -authenticationKeyIssuerID $ISSUER_ID \
      -authenticationKeyPath /tmp/key.p8
  - xcodebuild -exportArchive (ExportOptions method=app-store)
  - xcrun altool --upload-app -f *.ipa --apiKey $KEY_ID --apiIssuer $ISSUER_ID
  - ~5-15 min 后 build 在 TestFlight 可见
```
预算: ~10-15 min/次（weighted 100-150 min）。仅 main 触发，节省额度。

#### `manual-screenshot.yml` — workflow_dispatch
按 scenario 名跑指定 UI 测试 → 截图 → 上传。临时需求用。

### 6.2 截图覆盖的状态列表（UI test target）

1. AuthGate 空 / 填邮箱 / 填 OTP
2. CorpusView 公共未选 chip / 选 2 chip / 我的 tab
3. PhraseDetailView 整页（iframe 加载完）
4. LibraryView 列表 / 空状态
5. LibraryDetailView 竖屏（上下分）/ 横屏（overlay）/ 跟随播放中（某句高亮）/ 点高亮短语弹 popup
6. MeView 已登录有 license / 已登录无 license（含购买按钮）

**Mock 数据**通过 launch arguments 注入，避免 CI 真打后端 + 真 YouTube。

### 6.3 GitHub secrets

| Secret | 内容 |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | .p8 文件全文（含 `-----BEGIN PRIVATE KEY-----`） |
| `APP_STORE_CONNECT_KEY_ID` | 10 字符 |
| `APP_STORE_CONNECT_ISSUER_ID` | UUID |

无需 distribution certificate / provisioning profile（用 `-allowProvisioningUpdates` 让 xcodebuild 自动从 Apple 取）。

---

## 7. Apple Developer 一次性设置（owner 操作）

| 任务 | 状态 | 操作 |
|---|---|---|
| Apple Developer Program 会员（$99/年） | ✅ 已办 | — |
| App Store Connect API Key | ⏳ TODO | Connect → 用户和访问 → 集成 → "+" → Access: App Manager → 下载 .p8（只能下一次）+ 记 Key ID + Issuer ID |
| Bundle ID 注册 | ⏳ TODO | Developer Portal → Identifiers → "+" → `cc.eversay.whatsub.mobile`，不勾任何 capabilities |
| App Store Connect 应用记录 | ⏳ TODO | Connect → My Apps → "+" → iOS / 中文（简体）/ 选 Bundle ID / SKU 随意 / Full Access |
| TestFlight app 装到 iPhone / Mac | ⏳ TODO | App Store 搜 TestFlight → 登录 |
| GitHub secrets 配置 | ⏳ 我建仓后 | Settings → Secrets → 加 3 个 |

**不需要的事情**：
- ❌ 本地 CSR / Distribution Certificate / Provisioning Profile
- ❌ 本地 Xcode / fastlane

---

## 8. 工作量估算

| 工作单元 | 人天 |
|---|---|
| 后端（4 endpoint + 1 table + tests + 部署） | 1 |
| 桌面（同步 UI + Rust commands + tests + 联动删除） | 1.5 |
| iOS 纯写（SwiftUI 6 view + 网络 + 字幕 + Keychain） | 18-22 |
| CI/CD 三个 workflow + 第一次 TestFlight 跑通 | 3 |
| 真机调（user 反复装 + 反馈 + 修） | 3-5 |
| **合计** | **~5-6 周**（solo 全力） |

---

## 9. 风险与开放问题

| 风险 | 缓解 |
|---|---|
| GitHub macOS runner 免费额度 2000 min/月，weighted 10x，单次构建 ~10 min（weighted 100 min），实际约 20 次/月 | 仅 main 触发 TestFlight；PR 只跑 build + screenshot 不上传 TestFlight；超额买额度（$0.08/min weighted）|
| YouTube `youtube-nocookie.com` 嵌入受 YouTube 政策约束 | 仅用官方 IFrame Player API，符合 TOS；若未来嵌入被限，回退到 `m.youtube.com` deep link 跳原 app |
| WKWebView 在 iOS 16 不支持某些 IFrame API 事件 | 实测覆盖 iOS 16.0 / 16.4 / 17.x / 18.x；最坏退到 250ms polling |
| analysis_json 大字段在 Postgres 占空间 | TOAST 处理 OK 到 100 MB/行；30 GB DB 之前不切 OSS；schema 已留 `storage_location` hint 字段方便迁移 |
| 桌面 Tauri WebView fetch 失败（CSP/TLS）— 已知坑 | sync HTTP 走 Rust reqwest，复用 license.rs 模式 |
| TestFlight Internal Tester 限 100 人 | v1 阶段只有 owner 自测，远不到限额 |
| App Store 上架时审核可能因 YouTube 嵌入受质疑 | v2 上架前准备 demo 视频 + 说明文档，强调 IFrame API 合规；备选回退到 SFSafariViewController 跳网页 |

---

## 10. 验收标准（v1 完成的定义）

- [ ] 桌面端点 ☁️ 按钮能成功 sync 一条 YouTube 源 library 到云
- [ ] 桌面 Library 顶部「云同步详情」按钮能列出所有云端条目并支持下架
- [ ] 桌面删除已同步条目时弹联动删除选项，二者行为正确
- [ ] iOS 打开 app，未登录显示 AuthGateView，邮箱 OTP 流程能完整登录
- [ ] iOS 语料库 tab 公共/我的切换、tag chip 多选 AND 筛选都工作
- [ ] iOS 短语详情页 YouTube iframe 能播放，点 ▶ MM:SS 能 seek
- [ ] iOS Library tab 列出云上同步的条目，点击进详情
- [ ] iOS LibraryDetail 竖屏上下分 / 横屏 overlay 布局都正常
- [ ] iOS 字幕跟随播放自动滚动 + 当前句高亮
- [ ] iOS 字幕里 AI 高亮短语能点击弹 popup，「看详情」能跳 PhraseDetailView
- [ ] iOS 我的 tab 展示邮箱 + license 状态，未购用户能点跳 Safari 网站
- [ ] CI ci.yml 跑过、上传至少 12 张状态截图 artifact
- [ ] CI testflight.yml 推 main 分支后 ~15 min 内 TestFlight 出现新 build
- [ ] Owner 在 iPhone / Apple Silicon Mac 上能装 TestFlight build 并完整用一遍
