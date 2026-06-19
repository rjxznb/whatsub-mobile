# iOS Native YouTube Caption Extraction via Innertube

**Date**: 2026-06-19
**Owner**: rjxznb
**Target**: iOS 16.0+ (same as app)
**Replaces**: WKWebView + fetchHook caption extraction (~30% success rate against BotGuard)
**Net code change**: -400 LoC (delete 3 files, add 2 files)

---

## 1. Context

The current `CaptionExtractor.swift` loads a hidden WKWebView with the YouTube watch page, injects `fetchHook.js` to intercept the player's `/api/timedtext` requests, and parses the captured json3 body. This pretends to be a desktop Chrome browser to coax YouTube into serving the desktop player.

**It fails ~70% of the time** because YouTube's BotGuard fingerprints the WKWebView execution context (missing browser APIs, no real user gesture history, no visitor cookies). The timedtext URLs in the captionTracks response come back signed with a bot-flagged PO_TOKEN, and the actual fetch returns 404. We've shipped 9 fixes over two days (UA spoof, cookie persistence, homepage warmup, login-wall detection, target-video gating, scoped nudges, 60s timeout, etc.) — each helped a little but BotGuard always wins on hard cases.

**Root cause**: WKWebView gets the WEB client experience from YouTube. The WEB client has BotGuard, PO_TOKEN, and signature deobfuscation. Cookie-less WebKit can't satisfy any of these.

**The fix**: stop pretending to be a browser. Make a direct HTTP request to YouTube's Innertube API claiming to be the **Android YouTube app** (or `ANDROID_TESTSUITE` — even more lenient). YouTube serves Android clients via a different API path that has **no BotGuard, no PO_TOKEN, and no signature deobfuscation** — because Android native apps can't run JS sandboxes, so YouTube relies on different security (which it can't actually enforce from the server side without breaking the broader Android ecosystem).

This is the same path NewPipe (1B+ Android users), Invidious, LibreTube, and yt-dlp's `--extractor-args "youtube:player_client=android"` use. It's been stable for years.

---

## 2. Decisions (from brainstorm)

| Decision | Choice | Rationale |
|---|---|---|
| Replace vs additive | **Replace** + keep diagnostics | Two paths = 2x maintenance. The 5% YT.js can't solve, WKWebView can't either (same BotGuard) — keeping it is comfort, not coverage. |
| Cache | **Permanent disk cache** | YT captions rarely change; user-driven invalidation good enough; same pattern as `corpus_cache.json` / `roleplay_scenarios.json`. |
| Implementation | **Pure Swift Innertube client** (no JSC, no YouTube.js library) | Caption extraction needs no signature deobfuscation, no BotGuard handling, no Node compat — just 2 HTTP calls + JSON parsing. ~150 LoC Swift beats 1MB JS library when we use 0.5% of its surface. |
| Client context | `ANDROID_TESTSUITE` primary | Most permissive context YouTube ships. NewPipe and yt-dlp use it for caption extraction specifically. |
| Language strategy | English-only (manual > ASR > first English) | Same as today. The product is "learn English" — non-English captions don't fit. |
| Failure UX | Existing `CaptionDiagnosticsSheet` + "推送到桌面端" CTA unchanged | Diagnostic surfacing already shipped 2026-06-17; works well. |

---

## 3. Architecture

### File map

```
Delete (~600 LoC):
  whatsub-mobile/Import/CaptionExtractor.swift       — WKWebView + Continuation orchestration
  whatsub-mobile/Import/CaptionHookJS.swift          — main-world JS injection
  whatsub-mobile/Components/WKWebViewHost.swift      — SwiftUI WebView wrapper

Create (~200 LoC):
  whatsub-mobile/Import/YouTubeCaptionExtractor.swift   ~150 LoC — Innertube client
  whatsub-mobile/Import/CaptionCache.swift              ~50 LoC — disk cache

Keep unchanged:
  whatsub-mobile/Import/TimedtextParser.swift           — parseTimedtextJson3 (~30 LoC)
  whatsub-mobile/Import/CaptionDiagnosticsSheet.swift   — failure-path UI

Modify:
  whatsub-mobile/Import/ImportViewModel.swift           — call new extractor; remove WebView mount state
  whatsub-mobile/Import/ImportView.swift                — simplify .extracting UI (no WebView preview)
  whatsub-mobile/Me/MeView.swift                        — add "清除字幕缓存" entry (optional, 工具 section)
```

Net: **−400 LoC**, simpler mental model, no JS engine, no view-hierarchy mounting.

### Component contracts

**`YouTubeCaptionExtractor`** (stateless enum, like `Endpoints`):
```swift
enum YouTubeCaptionExtractor {
    static func extract(
        videoId: String,
        onProgress: @MainActor (String) -> Void = { _ in }
    ) async throws -> [Cue]
}
```

- One async function, throws `CaptionError`.
- `onProgress` is an optional debug-log emitter (replaces the current `appendDebug` ring buffer). Empty default means ImportView can ignore if it doesn't need diagnostics.
- Returns `[Cue]` directly (eliminates the intermediate `SpikeCue` → `Cue` map in current code).

**`CaptionCache`** (singleton, MainActor):
```swift
@MainActor
final class CaptionCache {
    static let shared = CaptionCache()
    func get(_ videoId: String) -> [Cue]?
    func set(_ videoId: String, cues: [Cue])
    func clearAll()
}
```

- Backed by `Caches/yt_captions/<videoId>.json` (one file per video).
- No TTL — permanent cache per design decision §2.
- File-per-video instead of a single index file: O(1) reads, atomic per-video writes, no merge contention.

---

## 4. Innertube extraction in detail

### 4.1 Client context constant

```swift
// Bundled in YouTubeCaptionExtractor.swift as a private constant.
// When YT changes context requirements (rare — last major change was ~2 years ago),
// update these strings and ship a new build. Source of truth for the latest
// working values: NewPipe's YoutubeParsingHelper.java + yt-dlp's
// extractor/youtube/_base.py.
private let innertubeContext: [String: Any] = [
    "client": [
        "clientName":         "ANDROID_TESTSUITE",
        "clientVersion":      "1.9",
        "androidSdkVersion":  30,
        "userAgent":          "com.google.android.youtube/19.07.34 (Linux; U; Android 14) gzip",
        "hl":                 "en",
        "gl":                 "US",
    ],
]

private let innertubePlayerURL = URL(string:
    "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
)!
```

### 4.2 Flow

```
extract(videoId)
  ↓
[1] Cache check: CaptionCache.get(videoId)
       HIT  → return cued cues (instant, no network)
       MISS → continue
  ↓
[2] Fetch player response:
       POST innertubePlayerURL
       Headers:
         Content-Type: application/json
         User-Agent: (matches context.client.userAgent)
         X-YouTube-Client-Name: 3   (ANDROID_TESTSUITE numeric id)
         X-YouTube-Client-Version: 1.9
       Body: { "context": <above>, "videoId": "<videoId>" }
       
       Expect 200; decode JSON.
       Status pre-check:
         playabilityStatus.status != "OK" → throw CaptionError mapped to status:
           "LOGIN_REQUIRED"          → .requiresLogin
           "AGE_VERIFICATION_REQUIRED" → .requiresLogin
           "ERROR" / "UNPLAYABLE"    → .videoUnavailable
           "LIVE_STREAM_OFFLINE"     → .videoUnavailable
  ↓
[3] Extract captionTracks:
       captions?.playerCaptionsTracklistRenderer?.captionTracks ?? []
       Empty → throw .noCaptions
  ↓
[4] Pick best English track:
       Prefer (in order):
         1. languageCode starts with "en", no `kind` field (manual)
         2. languageCode starts with "en", kind == "asr" (auto-generated)
         3. First track regardless of language (fallback — flagged in debug log)
       
       No English at all → throw .noEnglishCaptions
  ↓
[5] Fetch timedtext:
       url = pickedTrack.baseUrl + "&fmt=json3"
       GET it, expect 200, body is application/json
       
       Non-2xx → throw .timedtextFetchFailed(status)
       Empty body → throw .emptyResult
  ↓
[6] Parse json3:
       cues = parseTimedtextJson3(data)
       (existing function — no changes)
       
       Empty cues → throw .parseFailed
  ↓
[7] Write cache:
       CaptionCache.set(videoId, cues: cues)
       (best-effort; cache failure does NOT throw)
  ↓
[8] Return cues
```

### 4.3 ANDROID_TESTSUITE numeric client id

`X-YouTube-Client-Name: 3` — this is yt-dlp's mapping. The full table:
- 1: WEB
- 2: WEB_MOBILE  
- 3: ANDROID_TESTSUITE (alias for ANDROID with relaxed permissions)
- 5: IOS
- 56: WEB_EMBEDDED
- 85: TV_EMBEDDED

If `ANDROID_TESTSUITE` ever starts requiring PO_TOKEN (the risk identified in brainstorm), switch the constant block to `TV_EMBEDDED` (id 85) — TV clients have minimal anti-scraping because Apple TV / Roku / Smart TV ecosystem can't run BotGuard.

---

## 5. Caching

### 5.1 Disk layout

```
~/Library/Caches/<bundle-id>/yt_captions/
  <videoId-1>.json       ← raw JSON-encoded [Cue]
  <videoId-2>.json
  ...
```

Per-video files chosen over a single index because:
- Atomic writes per-video (no merge contention if user opens 2 videos in parallel).
- O(1) reads (no JSON parse of unrelated entries).
- iOS's cache eviction operates per-file — system can purge LRU entries cleanly.

### 5.2 Cache file format

```json
{
  "version": 1,
  "videoId": "G5wuhPjNfFI",
  "cachedAt": 1734567890.123,
  "cues": [
    { "index": 0, "time": 1.23, "endTime": 4.56, "text": "Hello world", "translation": "", "isKeyPoint": false, "highlightWords": [], "keyNotes": {}, "highlightTranslations": {} },
    ...
  ]
}
```

The cue shape mirrors `Cue` (existing `Encodable` synthesis works). `version: 1` allows future schema bump (older clients ignore unknown versions).

### 5.3 Eviction policy

**Permanent** per design §2. Three paths to eviction:
1. iOS system eviction (low storage, app uninstall) — cleans `Caches/` automatically.
2. User-initiated via `MeView → 工具 → 清除字幕缓存`.
3. Schema-version bump invalidates old entries (we read but skip on version mismatch).

### 5.4 Cache size envelope

- Per-video: 10-50 KB (text + timestamps).
- 1000 videos cached: 10-50 MB.
- Cache write fail-mode: log + continue (don't disrupt the user's extraction).

---

## 6. Error handling

### 6.1 New `CaptionError` enum

Replaces the existing `CaptionExtractor.CaptionError` (which had `.timeout`, `.emptyResult`, `.requiresLogin`):

```swift
enum CaptionError: Error, LocalizedError {
    case network(URLError)
    case http(status: Int)
    case videoUnavailable
    case requiresLogin
    case noCaptions             // captionTracks empty
    case noEnglishCaptions      // captionTracks present but no English
    case timedtextFetchFailed(status: Int)
    case parseFailed
    case emptyResult

    var errorDescription: String? { ... }
}
```

### 6.2 Failure-to-message map

| Error case | Chinese message | CTA shown |
|---|---|---|
| `.network` | "网络错误,请检查 VPN 或网络连接" | 重试 |
| `.http(status:)` | "YouTube 接口暂时不可用 (HTTP \(status))" | 重试 + 推送到桌面端 |
| `.videoUnavailable` | "视频不可用或已删除" | 重试 + 推送到桌面端 |
| `.requiresLogin` | "视频要求登录（年龄限制或会员）,iOS 无法满足,请推送到桌面端" | 推送到桌面端 |
| `.noCaptions` | "该视频没有字幕,可推送到桌面端用 Whisper 转录" | 推送到桌面端 |
| `.noEnglishCaptions` | "该视频没有英文字幕" | 推送到桌面端 |
| `.timedtextFetchFailed(status:)` | "字幕拉取失败 (HTTP \(status)),YouTube 可能临时拒绝服务" | 重试 + 推送到桌面端 |
| `.parseFailed` | "字幕格式异常,请稍后重试" | 重试 |
| `.emptyResult` | "字幕解析结果为空" | 推送到桌面端 |

### 6.3 Diagnostic log

`onProgress` callback in `extract()` is used by `ImportViewModel` to accumulate debug events for `CaptionDiagnosticsSheet`. Format mirrors the current `appendDebug` ring-buffer events:

```
[t=0.001] cache miss for G5wuhPjNfFI
[t=0.002] POST youtubei/v1/player + ANDROID_TESTSUITE
[t=0.345] player response: playabilityStatus=OK
[t=0.346] captionTracks: n=2
[t=0.347] picked en-US manual
[t=0.348] GET timedtext
[t=0.612] json3 body: len=12453
[t=0.614] parsed: 87 cues
[t=0.615] cache write
```

Available via `查看诊断` button on failure — same UI as today, just simpler events.

---

## 7. ImportView UI changes

### 7.1 `.extracting` body — simpler

Current `extractingBody` mounts a 320×180 visible `WKWebViewHost` showing the YT player. Replaced with a small spinner + status text:

```
       ⏳
       字幕提取中…
       通常 1-3 秒
```

Total render: a centered VStack with `ProgressView` + two labels. Removes ~40 LoC of WebView/host setup.

### 7.2 `pushOfferBody` — unchanged

The push-to-desktop card already handles all failure cases. New CaptionError mapping (§6.2) goes through the existing `.extractFailed(message, debug)` state.

### 7.3 MeView optional addition

In the existing `Section("工具")`:
```swift
Button("清除字幕缓存") { CaptionCache.shared.clearAll() }
    .foregroundStyle(.whatsubAccent)
```

Low priority — most users won't need this. Adds <20 LoC.

---

## 8. Testing

### 8.1 Unit tests (new)

`whatsub-mobileTests/YouTubeCaptionExtractorTests.swift`:
```swift
- testPickBestEnglishTrack_prefersManual()
- testPickBestEnglishTrack_fallsBackToASR()
- testPickBestEnglishTrack_throwsWhenNoEnglish()
- testMapPlayabilityStatus_loginRequired()
- testMapPlayabilityStatus_unplayable()
- testFetchPlayerResponse_handlesNon200()
```

`whatsub-mobileTests/CaptionCacheTests.swift`:
```swift
- testGet_returnsNil_whenMissing()
- testSetThenGet_roundtrip()
- testClearAll_emptiesDirectory()
- testGet_ignoresUnknownVersion()
```

`whatsub-mobileTests/TimedtextParserTests.swift` — already exists, no changes.

### 8.2 Mock strategy

`URLProtocol` subclass to mock HTTP responses without hitting the network. Same pattern the existing codebase uses (verify by checking `Tests/Networking/`).

### 8.3 Manual integration test before merge

5 real videos to verify against before pushing to TestFlight:

| Video category | Test videoId | Expected outcome |
|---|---|---|
| Standard public + EN captions | `dQw4w9WgXcQ` (Rick Astley) | Success, ~3-5s |
| Public + no captions | (find one with disabled CC) | `.noCaptions` → diagnostic + push-to-desktop |
| Age-restricted | (find an 18+) | `.requiresLogin` → push-to-desktop |
| Live stream | (active YT live) | Either success (live captions partial) or `.videoUnavailable` |
| Region-locked | (DE-only video) | `.videoUnavailable` |

These videos exercise the failure-message map end-to-end on real network.

---

## 9. Migration / rollout

### 9.1 Single commit, no feature flag

The new extractor REPLACES the old one — no A/B, no toggle. Reasons:
- Two paths = 2x maintenance permanently.
- The 5% the new path can't solve, the old path can't either (same BotGuard wall).
- Easy revert: `git revert <sha>` returns to WKWebView path; commit boundary is clean.

### 9.2 Rollout sequence

1. Code changes merged to `main` in one commit (with all 5 files: new extractor + cache, deleted 3 files, modified ImportViewModel/ImportView).
2. CI sim build passes.
3. TestFlight build deploys (next CI run).
4. Manual verification on physical iPhone — try 3 previously-failing videos.
5. If all 3 succeed → done.
6. If any fail → diagnose via the diagnostic sheet (the events §6.3 will identify which Innertube step broke).

### 9.3 Emergency revert path

If the new path fails catastrophically on prod (e.g., YouTube changes Android context requirements on the day we ship):

```bash
git revert <sha>
git push origin main
# Wait for CI + TestFlight (~10 min)
```

The WKWebView path is preserved in git history; revert is mechanical.

---

## 10. Risks + mitigation

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| `ANDROID_TESTSUITE` starts requiring PO_TOKEN | Low-Medium (1-2 years) | High (whole feature breaks) | Switch context block to `TV_EMBEDDED` (id 85) — one-line constant change |
| YouTube renames captionTracks field | Low (years stable) | High | Mirror yt-dlp commit; ~1h fix |
| User-Agent string gets blocked | Low (months) | Medium | Rotate UA every 3-6 months; track UA from NewPipe's latest constants |
| Innertube API URL change | Very low | High | Same Innertube URL has been stable since YT migrated to it (2016+) |
| YouTube blocks ANDROID context entirely | Very low | Catastrophic | Backend yt-dlp service fallback (the previously-discussed option) |
| Cache corruption on disk | Low | Low | Per-video files isolate damage; corrupt entry just refetches |

### Critical risk: 1-2 year horizon on ANDROID_TESTSUITE

YouTube's reverse-engineering arms race is escalating. PO_TOKEN started leaking into Android API contexts in 2024 for video URL extraction. Currently NOT required for captions, but plausibly will be in 18-24 months.

When that happens:
- TV_EMBEDDED is the next-cleanest target.
- If TV_EMBEDDED also gets locked: backend service is the architectural fallback (already designed, just not built).

This is acceptable risk given:
1. We're shipping iOS independence today, not solving the next 5 years.
2. Production yt-dlp has weathered every YT change since 2014 — community moves fast.
3. The product value (captions for English learning) doesn't depend on undecodable parts of the YT pipeline.

---

## 11. Non-goals

- **Non-English captions**. Product is "learn English"; non-English doesn't fit the user model.
- **Video downloading**. Apple Review rejects YT downloaders; users don't want 500MB videos on their phone. Desktop handles this.
- **Live caption streaming**. Live streams return partial captions; we explicitly throw `.videoUnavailable` for them and direct to desktop (where post-live whisper transcription is more reliable).
- **Subtitle editing in the extractor**. The existing `字幕编辑 P1+P2` flow handles user-side editing post-extraction. The extractor is read-only.
- **Backend caching**. Cache stays per-device. No server, no shared cache, no extra infrastructure cost.
- **Migration of existing users' WKWebView-cached state**. There is no cache today; nothing to migrate.

---

## 12. Estimate

| Stage | Effort |
|---|---|
| Implementation (extractor + cache + UI integration) | 1 day |
| Unit tests | 0.5 day |
| Manual integration + iteration | 0.5 day |
| **Total** | **~2 days** |

---

## 13. Open questions resolved during brainstorm

| Question | Resolution |
|---|---|
| Replace old WKWebView path or run both? | Replace (§2) |
| Cache extracted captions on disk? | Permanent cache (§2, §5) |
| Use YouTube.js or pure Swift? | Pure Swift — caption extraction doesn't need YT.js's JS-only features (BotGuard handling, signature decoding) |
| Which client context? | `ANDROID_TESTSUITE` primary, `TV_EMBEDDED` fallback if first fails in the future |
| Language fallback? | English-only (manual > ASR), throw if no English |
| Feature flag for rollout? | No — clean replace with mechanical revert path |
| iOS minimum bump? | No — Foundation/URLSession requirements work on iOS 16 |

Implementation plan to follow via `writing-plans` skill.
