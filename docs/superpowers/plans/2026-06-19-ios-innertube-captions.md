# iOS Native YouTube Caption Extraction via Innertube — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the WKWebView + fetchHook caption extractor with a pure-Swift HTTP client that calls YouTube's Innertube API as ANDROID_TESTSUITE, bypassing BotGuard entirely.

**Architecture:** Single new `YouTubeCaptionExtractor.swift` (~150 LoC) makes two HTTP calls (POST player API → GET timedtext JSON), reuses the existing `parseTimedtextJson3`, and stores results in a per-video disk cache (`CaptionCache.swift`, ~50 LoC). Delete the three WKWebView-path files (~600 LoC). Net change: −400 LoC.

**Tech Stack:** Swift 5.10, Foundation/URLSession, XCTest (no new dependencies). iOS 16+.

## Global Constraints

- Bundle identifier: `cc.eversay.whatsub.mobile`
- Module name: `whatsub_mobile` (used as `@testable import whatsub_mobile` in tests)
- Test framework: XCTest (NOT Swift Testing); base class `XCTestCase`
- Test target directory: `whatsub-mobileTests/`
- Cache directory: `~/Library/Caches/<bundle-id>/yt_captions/`
- Innertube URL (verbatim from spec §4.1): `https://www.youtube.com/youtubei/v1/player?prettyPrint=false`
- Client name (spec §4.1): `ANDROID_TESTSUITE`
- Client version (spec §4.1): `1.9`
- Android SDK version (spec §4.1): `30`
- User-Agent (spec §4.1): `com.google.android.youtube/19.07.34 (Linux; U; Android 14) gzip`
- X-YouTube-Client-Name header value (spec §4.3): `3`
- X-YouTube-Client-Version header value (spec §4.3): `1.9`
- Spec source: `docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md`

---

## Phase 1 — Foundations (TDD)

### Task 1.1: CaptionError enum + LocalizedError messages

**Files:**
- Create: `whatsub-mobile/Import/CaptionError.swift`
- Create: `whatsub-mobileTests/CaptionErrorTests.swift`

**Interfaces:**
- Consumes: nothing (foundational type)
- Produces:
  - `enum CaptionError: Error, LocalizedError` with cases: `.network(URLError)`, `.http(status: Int)`, `.videoUnavailable`, `.requiresLogin`, `.noCaptions`, `.noEnglishCaptions`, `.timedtextFetchFailed(status: Int)`, `.parseFailed`, `.emptyResult`
  - Each case has a Chinese `errorDescription` per spec §6.2

- [ ] **Step 1: Write the failing test**

Create `whatsub-mobileTests/CaptionErrorTests.swift`:

```swift
import XCTest
@testable import whatsub_mobile

final class CaptionErrorTests: XCTestCase {

    func testNetworkErrorMessage() {
        let underlying = URLError(.notConnectedToInternet)
        let err = CaptionError.network(underlying)
        XCTAssertEqual(err.errorDescription, "网络错误,请检查 VPN 或网络连接")
    }

    func testHTTPErrorMessageIncludesStatus() {
        XCTAssertEqual(CaptionError.http(status: 503).errorDescription,
                       "YouTube 接口暂时不可用 (HTTP 503)")
    }

    func testVideoUnavailableMessage() {
        XCTAssertEqual(CaptionError.videoUnavailable.errorDescription,
                       "视频不可用或已删除")
    }

    func testRequiresLoginMessage() {
        XCTAssertEqual(CaptionError.requiresLogin.errorDescription,
                       "视频要求登录（年龄限制或会员）,iOS 无法满足,请推送到桌面端")
    }

    func testNoCaptionsMessage() {
        XCTAssertEqual(CaptionError.noCaptions.errorDescription,
                       "该视频没有字幕,可推送到桌面端用 Whisper 转录")
    }

    func testNoEnglishCaptionsMessage() {
        XCTAssertEqual(CaptionError.noEnglishCaptions.errorDescription,
                       "该视频没有英文字幕")
    }

    func testTimedtextFetchFailedMessage() {
        XCTAssertEqual(CaptionError.timedtextFetchFailed(status: 404).errorDescription,
                       "字幕拉取失败 (HTTP 404),YouTube 可能临时拒绝服务")
    }

    func testParseFailedMessage() {
        XCTAssertEqual(CaptionError.parseFailed.errorDescription,
                       "字幕格式异常,请稍后重试")
    }

    func testEmptyResultMessage() {
        XCTAssertEqual(CaptionError.emptyResult.errorDescription,
                       "字幕解析结果为空")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing whatsub-mobileTests/CaptionErrorTests`
Expected: 9 FAIL with "Cannot find type 'CaptionError' in scope"

(Or if running on CI, simply push and let CI fail with the same.)

- [ ] **Step 3: Create the enum + messages**

Create `whatsub-mobile/Import/CaptionError.swift`:

```swift
import Foundation

/// All failure paths the iOS-native YouTube caption extractor can surface.
/// Replaces the legacy WKWebView-based `CaptionExtractor.CaptionError` which
/// only carried `.timeout`, `.emptyResult`, and `.requiresLogin`.
///
/// Message strings are sourced verbatim from
/// `docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md` §6.2
/// and exposed to the user via `LocalizedError.errorDescription`. The
/// ImportView failure card renders them inline; the
/// CaptionDiagnosticsSheet button surfaces the per-step debug log
/// separately.
enum CaptionError: Error, LocalizedError {
    case network(URLError)
    case http(status: Int)
    case videoUnavailable
    case requiresLogin
    case noCaptions
    case noEnglishCaptions
    case timedtextFetchFailed(status: Int)
    case parseFailed
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .network:
            return "网络错误,请检查 VPN 或网络连接"
        case .http(let status):
            return "YouTube 接口暂时不可用 (HTTP \(status))"
        case .videoUnavailable:
            return "视频不可用或已删除"
        case .requiresLogin:
            return "视频要求登录（年龄限制或会员）,iOS 无法满足,请推送到桌面端"
        case .noCaptions:
            return "该视频没有字幕,可推送到桌面端用 Whisper 转录"
        case .noEnglishCaptions:
            return "该视频没有英文字幕"
        case .timedtextFetchFailed(let status):
            return "字幕拉取失败 (HTTP \(status)),YouTube 可能临时拒绝服务"
        case .parseFailed:
            return "字幕格式异常,请稍后重试"
        case .emptyResult:
            return "字幕解析结果为空"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same xcodebuild command from Step 2.
Expected: 9 PASS.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Import/CaptionError.swift whatsub-mobileTests/CaptionErrorTests.swift
git commit -m "feat(import): CaptionError enum with localized Chinese messages

Foundational type for the new iOS-native YouTube caption extractor
(spec §6.2). Replaces the WKWebView path's three-case CaptionError
with nine explicit cases that map every Innertube failure mode to a
user-facing Chinese message. LocalizedError conformance feeds
ImportView's existing .extractFailed state without further wiring.

Tests cover each case's errorDescription verbatim."
```

---

### Task 1.2: CaptionCache (disk-backed, per-video JSON files)

**Files:**
- Create: `whatsub-mobile/Import/CaptionCache.swift`
- Create: `whatsub-mobileTests/CaptionCacheTests.swift`

**Interfaces:**
- Consumes: `Cue` type from `Networking/DTOs.swift` (already exists, `Codable`)
- Produces:
  - `final class CaptionCache` with public static `shared: CaptionCache`
  - `func get(_ videoId: String) -> [Cue]?` — returns nil on miss / unreadable / wrong version
  - `func set(_ videoId: String, cues: [Cue])` — best-effort write, never throws
  - `func clearAll()` — removes the cache directory contents
  - Optional `init(directory: URL)` for tests (production constructs via singleton)
  - File format on disk: `Caches/yt_captions/<videoId>.json` containing JSON with `version`, `videoId`, `cachedAt`, `cues` fields (spec §5.2)

- [ ] **Step 1: Write the failing test**

Create `whatsub-mobileTests/CaptionCacheTests.swift`:

```swift
import XCTest
@testable import whatsub_mobile

final class CaptionCacheTests: XCTestCase {

    private var tempDir: URL!
    private var cache: CaptionCache!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaptionCacheTests-\(UUID().uuidString)",
                                    isDirectory: true)
        cache = CaptionCache(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeCue(idx: Int) -> Cue {
        Cue(index: idx, time: Double(idx) * 1.5,
            endTime: Double(idx) * 1.5 + 1.5,
            text: "line \(idx)")
    }

    func testGetReturnsNilWhenMissing() {
        XCTAssertNil(cache.get("unknown_video_id"))
    }

    func testSetThenGetRoundtrip() {
        let cues = [makeCue(idx: 0), makeCue(idx: 1)]
        cache.set("abc123", cues: cues)
        let loaded = cache.get("abc123")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?[0].text, "line 0")
        XCTAssertEqual(loaded?[0].time, 0.0, accuracy: 0.001)
        XCTAssertEqual(loaded?[1].endTime, 3.0, accuracy: 0.001)
    }

    func testClearAllEmptiesDirectory() {
        cache.set("a", cues: [makeCue(idx: 0)])
        cache.set("b", cues: [makeCue(idx: 1)])
        XCTAssertNotNil(cache.get("a"))
        XCTAssertNotNil(cache.get("b"))
        cache.clearAll()
        XCTAssertNil(cache.get("a"))
        XCTAssertNil(cache.get("b"))
    }

    func testGetIgnoresUnknownVersion() throws {
        // Write a file claiming version 999 — current code rejects unknown
        // versions so it can evolve the schema later (spec §5.3).
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
        let path = tempDir.appendingPathComponent("v999.json")
        let payload: [String: Any] = [
            "version": 999,
            "videoId": "v999",
            "cachedAt": Date().timeIntervalSince1970,
            "cues": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: path)
        XCTAssertNil(cache.get("v999"))
    }

    func testGetReturnsNilOnCorruptFile() throws {
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
        let path = tempDir.appendingPathComponent("corrupt.json")
        try "not json".data(using: .utf8)!.write(to: path)
        XCTAssertNil(cache.get("corrupt"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing whatsub-mobileTests/CaptionCacheTests`
Expected: 5 FAIL with "Cannot find type 'CaptionCache' in scope"

- [ ] **Step 3: Implement CaptionCache**

Create `whatsub-mobile/Import/CaptionCache.swift`:

```swift
import Foundation

/// Per-video disk cache for YouTube caption extraction results.
///
/// Layout: `<directory>/<videoId>.json` — one file per video. Each file
/// is a small JSON object (`version`, `videoId`, `cachedAt`, `cues`).
/// Per-video files were chosen over a single index because:
///   1. Atomic writes per-video (no merge contention if the user opens
///      two videos in parallel — the second write doesn't have to read
///      and rewrite a shared index).
///   2. O(1) reads — no parse of unrelated cached videos.
///   3. iOS's cache eviction can purge individual files cleanly when
///      storage is tight.
///
/// Eviction: there is no TTL (spec §5.3). Files are removed by
/// `clearAll()`, by iOS itself under storage pressure (the directory
/// lives under `~/Library/Caches/` which iOS may sweep), or by a future
/// schema version bump (unknown `version` is rejected on read, so old
/// entries become invisible without an explicit purge step).
///
/// Spec source: `docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md` §5.
final class CaptionCache {

    static let shared = CaptionCache()

    private let directory: URL
    private let currentVersion = 1

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory,
                                                  in: .userDomainMask)[0]
            self.directory = caches.appendingPathComponent("yt_captions",
                                                           isDirectory: true)
        }
    }

    func get(_ videoId: String) -> [Cue]? {
        let path = directory.appendingPathComponent("\(videoId).json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let payload = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return nil
        }
        guard payload.version == currentVersion else { return nil }
        return payload.cues
    }

    func set(_ videoId: String, cues: [Cue]) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let payload = CacheFile(
                version: currentVersion,
                videoId: videoId,
                cachedAt: Date().timeIntervalSince1970,
                cues: cues
            )
            let data = try JSONEncoder().encode(payload)
            let path = directory.appendingPathComponent("\(videoId).json")
            try data.write(to: path, options: .atomic)
        } catch {
            // Best-effort: a failed cache write must never disrupt the
            // user's extraction flow. The next extract() will hit the
            // network again — annoying but recoverable.
        }
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct CacheFile: Codable {
        let version: Int
        let videoId: String
        let cachedAt: Double
        let cues: [Cue]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same xcodebuild command from Step 2.
Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Import/CaptionCache.swift whatsub-mobileTests/CaptionCacheTests.swift
git commit -m "feat(import): CaptionCache — per-video disk cache for caption extraction

Spec §5 implementation. Per-video JSON files at Caches/yt_captions/
<videoId>.json — atomic writes, O(1) reads, lets iOS sweep individual
entries under storage pressure. Permanent (no TTL); evicted only by
clearAll(), iOS system pressure, or schema version bump.

Best-effort writes never throw — a failed cache write must not disrupt
extraction. Unknown schema versions are silently treated as misses so
future bumps don't crash older clients.

Cue is already Codable in DTOs.swift; reuses the synthesized
implementation. Tests cover round-trip, missing, corrupt, and
unknown-version paths."
```

---

### Task 1.3: Innertube response models + track-picking helper

**Files:**
- Create: `whatsub-mobile/Import/InnertubeModels.swift`
- Create: `whatsub-mobileTests/InnertubeModelsTests.swift`

**Interfaces:**
- Consumes: nothing (pure types + a pure function)
- Produces:
  - `struct PlayerResponse: Decodable` with `playabilityStatus: PlayabilityStatus` and optional `captions: CaptionsContainer`
  - `struct PlayabilityStatus: Decodable` with `status: String`
  - `struct CaptionsContainer: Decodable` with `playerCaptionsTracklistRenderer: TracklistRenderer?`
  - `struct TracklistRenderer: Decodable` with `captionTracks: [CaptionTrack]`
  - `struct CaptionTrack: Decodable` with `baseUrl: String`, `languageCode: String`, optional `kind: String?`
  - `func pickBestEnglishCaptionTrack(_ tracks: [CaptionTrack]) -> CaptionTrack?` — prefer English manual > English ASR > nil (spec §4.2 step 4)

- [ ] **Step 1: Write the failing test**

Create `whatsub-mobileTests/InnertubeModelsTests.swift`:

```swift
import XCTest
@testable import whatsub_mobile

final class InnertubeModelsTests: XCTestCase {

    private func track(language: String, kind: String? = nil,
                       baseUrl: String = "https://example.com") -> CaptionTrack {
        CaptionTrack(baseUrl: baseUrl, languageCode: language, kind: kind)
    }

    func testPicksEnglishManualOverASR() {
        let picked = pickBestEnglishCaptionTrack([
            track(language: "en", kind: "asr",
                  baseUrl: "https://example.com/asr"),
            track(language: "en", kind: nil,
                  baseUrl: "https://example.com/manual"),
        ])
        XCTAssertEqual(picked?.baseUrl, "https://example.com/manual",
                       "manual track must win over ASR even when ASR comes first")
    }

    func testFallsBackToASRWhenNoManual() {
        let picked = pickBestEnglishCaptionTrack([
            track(language: "en", kind: "asr"),
        ])
        XCTAssertEqual(picked?.kind, "asr")
    }

    func testReturnsNilWhenNoEnglish() {
        let picked = pickBestEnglishCaptionTrack([
            track(language: "es"),
            track(language: "fr"),
            track(language: "ja", kind: "asr"),
        ])
        XCTAssertNil(picked)
    }

    func testMatchesEnglishVariants() {
        // YouTube sometimes returns "en-US" / "en-GB" — our check uses
        // hasPrefix("en") so these should all count as English.
        XCTAssertNotNil(pickBestEnglishCaptionTrack([track(language: "en-US")]))
        XCTAssertNotNil(pickBestEnglishCaptionTrack([track(language: "en-GB")]))
    }

    func testDecodesPlayerResponse() throws {
        let json = #"""
        {
          "playabilityStatus": { "status": "OK" },
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                { "baseUrl": "https://example.com/t1", "languageCode": "en-US" },
                { "baseUrl": "https://example.com/t2", "languageCode": "en", "kind": "asr" }
              ]
            }
          }
        }
        """#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PlayerResponse.self, from: json)
        XCTAssertEqual(resp.playabilityStatus.status, "OK")
        XCTAssertEqual(resp.captions?.playerCaptionsTracklistRenderer?
                            .captionTracks.count, 2)
    }

    func testDecodesWhenCaptionsAbsent() throws {
        // Videos without any captions return a player response with no
        // `captions` key at all. The decode must succeed; the extractor
        // turns the missing captions into CaptionError.noCaptions.
        let json = #"""
        { "playabilityStatus": { "status": "OK" } }
        """#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PlayerResponse.self, from: json)
        XCTAssertNil(resp.captions)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing whatsub-mobileTests/InnertubeModelsTests`
Expected: 6 FAIL with "Cannot find type 'CaptionTrack' in scope" etc.

- [ ] **Step 3: Create the models + helper**

Create `whatsub-mobile/Import/InnertubeModels.swift`:

```swift
import Foundation

/// Decoded subset of the youtubei `/v1/player` response we care about.
/// Only fields the caption pipeline actually reads are modelled — most
/// of the response (streamingData, videoDetails, microformat, etc.)
/// is irrelevant for caption extraction and remains unparsed.
struct PlayerResponse: Decodable {
    let playabilityStatus: PlayabilityStatus
    let captions: CaptionsContainer?
}

struct PlayabilityStatus: Decodable {
    /// YouTube's terminology — values we observe in practice: "OK",
    /// "ERROR", "UNPLAYABLE", "LOGIN_REQUIRED", "AGE_VERIFICATION_REQUIRED",
    /// "LIVE_STREAM_OFFLINE". The extractor maps these to CaptionError
    /// cases in YouTubeCaptionExtractor.
    let status: String
}

struct CaptionsContainer: Decodable {
    let playerCaptionsTracklistRenderer: TracklistRenderer?
}

struct TracklistRenderer: Decodable {
    let captionTracks: [CaptionTrack]
}

struct CaptionTrack: Decodable {
    /// Signed URL where YouTube serves the actual timedtext payload.
    /// Append `&fmt=json3` to request the JSON format our parser
    /// already understands (see TimedtextParser.swift).
    let baseUrl: String
    /// BCP-47 language code, sometimes with region suffix ("en", "en-US",
    /// "en-GB", "es", "ja", etc.). We treat anything starting with "en"
    /// as English.
    let languageCode: String
    /// "asr" for auto-generated, absent for manual. Manual is preferred
    /// because it's usually creator-authored and higher quality.
    let kind: String?
}

/// Pick the best English caption track from a YouTube response.
///
/// Priority order (spec §4.2 step 4):
///   1. English-language with no `kind` (manual / creator-authored)
///   2. English-language with `kind == "asr"` (auto-generated)
///   3. nil — caller throws CaptionError.noEnglishCaptions
///
/// "English-language" means `languageCode.hasPrefix("en")` so en, en-US,
/// en-GB all match. The legacy plugin's behaviour matched only
/// `languageCode == "en"` and missed regional variants on some videos —
/// the prefix check fixes that.
func pickBestEnglishCaptionTrack(_ tracks: [CaptionTrack]) -> CaptionTrack? {
    if let manual = tracks.first(where: {
        $0.languageCode.hasPrefix("en") && $0.kind == nil
    }) {
        return manual
    }
    if let asr = tracks.first(where: {
        $0.languageCode.hasPrefix("en") && $0.kind == "asr"
    }) {
        return asr
    }
    return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same xcodebuild command from Step 2.
Expected: 6 PASS.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Import/InnertubeModels.swift whatsub-mobileTests/InnertubeModelsTests.swift
git commit -m "feat(import): Innertube response models + track-picking helper

Minimal Decodable subset of YouTube's /v1/player response for caption
extraction (spec §4). Only models the fields we read — streaming data,
microformat, etc. stay unparsed. The track-picker prioritises English
manual > English ASR > nil, matching plugin behaviour but using
languageCode.hasPrefix(\"en\") so en-US / en-GB also count.

Pure types + a pure function — no I/O, fully unit-testable."
```

---

## Phase 2 — Innertube extraction

### Task 2.1: YouTubeCaptionExtractor with HTTPFetcher injection

**Files:**
- Create: `whatsub-mobile/Import/YouTubeCaptionExtractor.swift`
- Create: `whatsub-mobileTests/YouTubeCaptionExtractorTests.swift`

**Interfaces:**
- Consumes:
  - `Cue` from `Networking/DTOs.swift`
  - `parseTimedtextJson3(_ data: Data) -> [SpikeCue]` from `Import/TimedtextParser.swift` — produces `SpikeCue` with `idx`, `time`, `end`, `text` fields
  - `CaptionError` from Task 1.1
  - `CaptionCache` from Task 1.2
  - `PlayerResponse`, `CaptionTrack`, `pickBestEnglishCaptionTrack` from Task 1.3
- Produces:
  - `enum YouTubeCaptionExtractor` namespace
  - `typealias HTTPFetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)`
  - `static func extract(videoId: String, cache: CaptionCache = .shared, fetcher: @escaping HTTPFetcher = ..., onProgress: @MainActor @escaping (String) -> Void = { _ in }) async throws -> [Cue]`

- [ ] **Step 1: Write the failing tests**

Create `whatsub-mobileTests/YouTubeCaptionExtractorTests.swift`:

```swift
import XCTest
@testable import whatsub_mobile

final class YouTubeCaptionExtractorTests: XCTestCase {

    private var tempDir: URL!
    private var cache: CaptionCache!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("YTExtractorTests-\(UUID().uuidString)",
                                    isDirectory: true)
        cache = CaptionCache(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Build a JSON-format timedtext (json3) body matching what the
    /// extractor's parseTimedtextJson3 dependency expects.
    private func makeTimedtextJson3() -> Data {
        let json = """
        {"events":[
          {"tStartMs":0,"dDurationMs":1500,"segs":[{"utf8":"Hello"}]},
          {"tStartMs":1500,"dDurationMs":1500,"segs":[{"utf8":"World"}]}
        ]}
        """
        return json.data(using: .utf8)!
    }

    private func ok(_ data: Data) -> (Data, URLResponse) {
        let resp = HTTPURLResponse(url: URL(string: "https://x")!,
                                   statusCode: 200,
                                   httpVersion: nil,
                                   headerFields: nil)!
        return (data, resp)
    }

    private func status(_ code: Int) -> (Data, URLResponse) {
        let resp = HTTPURLResponse(url: URL(string: "https://x")!,
                                   statusCode: code,
                                   httpVersion: nil,
                                   headerFields: nil)!
        return (Data(), resp)
    }

    // MARK: - Happy path

    func testExtractHappyPath() async throws {
        let playerJSON = """
        {
          "playabilityStatus": {"status": "OK"},
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {"baseUrl": "https://yt.example/timedtext?v=abc",
                 "languageCode": "en"}
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let timedtextData = makeTimedtextJson3()
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { req in
            calls += 1
            switch calls {
            case 1:
                XCTAssertEqual(req.httpMethod, "POST")
                XCTAssertTrue(req.url?.absoluteString
                              .contains("youtubei/v1/player") ?? false)
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-YouTube-Client-Name"),
                               "3")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-YouTube-Client-Version"),
                               "1.9")
                XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"),
                               "application/json")
                return self.ok(playerJSON)
            case 2:
                XCTAssertEqual(req.httpMethod, "GET")
                XCTAssertTrue(req.url?.absoluteString
                              .contains("yt.example/timedtext") ?? false)
                XCTAssertTrue(req.url?.absoluteString
                              .contains("fmt=json3") ?? false)
                return self.ok(timedtextData)
            default:
                XCTFail("unexpected request")
                return self.status(500)
            }
        }
        let cues = try await YouTubeCaptionExtractor.extract(
            videoId: "abc",
            cache: cache,
            fetcher: fetcher
        )
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello")
        XCTAssertEqual(cues[1].text, "World")
    }

    // MARK: - Cache

    func testReturnsCachedOnHit() async throws {
        cache.set("cached_id", cues: [
            Cue(index: 0, time: 0, endTime: 1, text: "From cache")
        ])
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return self.status(500)
        }
        let cues = try await YouTubeCaptionExtractor.extract(
            videoId: "cached_id",
            cache: cache,
            fetcher: fetcher
        )
        XCTAssertEqual(calls, 0, "fetcher must not run when cache hits")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "From cache")
    }

    func testWritesCacheOnSuccess() async throws {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return calls == 1 ? self.ok(playerJSON) : self.ok(self.makeTimedtextJson3())
        }
        _ = try await YouTubeCaptionExtractor.extract(
            videoId: "writeback",
            cache: cache,
            fetcher: fetcher
        )
        XCTAssertNotNil(cache.get("writeback"),
                        "successful extract must populate the cache")
    }

    // MARK: - Failure cases

    func testThrowsRequiresLoginForAgeGate() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"LOGIN_REQUIRED"}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "gated", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.requiresLogin = error else {
                XCTFail("expected .requiresLogin, got \(error)"); return
            }
        }
    }

    func testThrowsVideoUnavailableForUnplayable() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"UNPLAYABLE"}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.videoUnavailable = error else {
                XCTFail("expected .videoUnavailable, got \(error)"); return
            }
        }
    }

    func testThrowsNoCaptions() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.noCaptions = error else {
                XCTFail("expected .noCaptions, got \(error)"); return
            }
        }
    }

    func testThrowsNoEnglishCaptions() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://x","languageCode":"es"}
         ]}}}
        """.data(using: .utf8)!
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.ok(playerJSON) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.noEnglishCaptions = error else {
                XCTFail("expected .noEnglishCaptions, got \(error)"); return
            }
        }
    }

    func testThrowsHTTPOnNon200Player() async {
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in self.status(503) }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.http(let status) = error else {
                XCTFail("expected .http, got \(error)"); return
            }
            XCTAssertEqual(status, 503)
        }
    }

    func testThrowsTimedtextFetchFailedOnNon200Timedtext() async {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return calls == 1 ? self.ok(playerJSON) : self.status(404)
        }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.timedtextFetchFailed(let status) = error else {
                XCTFail("expected .timedtextFetchFailed, got \(error)"); return
            }
            XCTAssertEqual(status, 404)
        }
    }

    func testThrowsNetworkOnURLError() async {
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            throw URLError(.notConnectedToInternet)
        }
        await XCTAssertThrowsErrorAsync(
            try await YouTubeCaptionExtractor.extract(
                videoId: "x", cache: cache, fetcher: fetcher
            )
        ) { error in
            guard case CaptionError.network = error else {
                XCTFail("expected .network, got \(error)"); return
            }
        }
    }

    // MARK: - Progress events

    func testEmitsProgressEvents() async throws {
        let playerJSON = """
        {"playabilityStatus":{"status":"OK"},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://yt.example/timedtext","languageCode":"en"}
         ]}}}
        """.data(using: .utf8)!
        var calls = 0
        let fetcher: YouTubeCaptionExtractor.HTTPFetcher = { _ in
            calls += 1
            return calls == 1 ? self.ok(playerJSON) : self.ok(self.makeTimedtextJson3())
        }
        var events: [String] = []
        let collect: @MainActor (String) -> Void = { events.append($0) }
        _ = try await YouTubeCaptionExtractor.extract(
            videoId: "x", cache: cache, fetcher: fetcher, onProgress: collect
        )
        XCTAssertTrue(events.contains(where: { $0.contains("cache miss") }))
        XCTAssertTrue(events.contains(where: { $0.contains("POST youtubei") }))
        XCTAssertTrue(events.contains(where: { $0.contains("captionTracks") }))
        XCTAssertTrue(events.contains(where: { $0.contains("picked") }))
        XCTAssertTrue(events.contains(where: { $0.contains("parsed") }))
    }
}

// MARK: - Test helper

/// Async equivalent of XCTAssertThrowsError. Captures any thrown error
/// and routes it through `errorHandler` so tests can pattern-match the
/// CaptionError case.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected error, got success", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing whatsub-mobileTests/YouTubeCaptionExtractorTests`
Expected: 10 FAIL with "Cannot find type 'YouTubeCaptionExtractor' in scope"

- [ ] **Step 3: Implement the extractor**

Create `whatsub-mobile/Import/YouTubeCaptionExtractor.swift`:

```swift
import Foundation

/// Pure-Swift YouTube caption extractor. Calls Innertube's `/v1/player`
/// API claiming to be the ANDROID_TESTSUITE client, parses the
/// returned captionTracks, downloads the timedtext json3 payload for
/// the best-English track, and hands the resulting cues to the caller.
///
/// Architecture decision (spec §2): pure HTTP — no WKWebView, no
/// JavaScriptCore, no embedded YouTube.js. Caption extraction is the
/// 0.5% of yt-dlp's surface that doesn't need BotGuard / PO_TOKEN /
/// signature deobfuscation, because YouTube serves Android-claiming
/// clients via a different API path entirely.
///
/// Risks (spec §10):
///   - ANDROID_TESTSUITE may start requiring PO_TOKEN on a 1-2 year
///     horizon. Mitigation: change the `clientName` constant to
///     `TV_EMBEDDED` and the X-YouTube-Client-Name header to "85".
///   - Innertube schema changes are rare (years stable) — mirror
///     yt-dlp/NewPipe commits if they ship before us.
enum YouTubeCaptionExtractor {

    /// Function-type alias for HTTP injection. Tests pass a mock; production
    /// passes `URLSession.shared.data(for:)`. Default value below.
    typealias HTTPFetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Default HTTP implementation: vanilla URLSession.shared. Tests
    /// override this argument to return canned `(Data, URLResponse)`
    /// tuples without hitting the network.
    static let defaultFetcher: HTTPFetcher = { request in
        try await URLSession.shared.data(for: request)
    }

    /// Extract English captions for a YouTube videoId.
    ///
    /// - Parameters:
    ///   - videoId: 11-char YouTube videoId.
    ///   - cache: Disk cache. Hits skip the network entirely.
    ///   - fetcher: HTTP function. Defaults to URLSession.shared.
    ///   - onProgress: Receives one debug-log line per extraction step.
    ///     ImportViewModel accumulates these for the `查看诊断` sheet.
    /// - Returns: `[Cue]` with index, time, endTime, text populated;
    ///   translation / highlights remain empty until AnalysisEngine runs.
    /// - Throws: `CaptionError` covering every failure mode.
    static func extract(
        videoId: String,
        cache: CaptionCache = .shared,
        fetcher: @escaping HTTPFetcher = defaultFetcher,
        onProgress: @MainActor @escaping (String) -> Void = { _ in }
    ) async throws -> [Cue] {

        await emit(onProgress, "extract(videoId=\(videoId)) start")

        // 1. Cache check.
        if let cached = cache.get(videoId) {
            await emit(onProgress, "cache hit for \(videoId)")
            return cached
        }
        await emit(onProgress, "cache miss for \(videoId)")

        // 2. POST youtubei/v1/player.
        await emit(onProgress, "POST youtubei/v1/player + ANDROID_TESTSUITE")
        let playerResponse = try await fetchPlayerResponse(
            videoId: videoId, fetcher: fetcher
        )

        // 3. Map playabilityStatus.
        switch playerResponse.playabilityStatus.status {
        case "OK":
            break
        case "LOGIN_REQUIRED", "AGE_VERIFICATION_REQUIRED":
            await emit(onProgress, "playabilityStatus=\(playerResponse.playabilityStatus.status) → requiresLogin")
            throw CaptionError.requiresLogin
        case "ERROR", "UNPLAYABLE", "LIVE_STREAM_OFFLINE":
            await emit(onProgress, "playabilityStatus=\(playerResponse.playabilityStatus.status) → videoUnavailable")
            throw CaptionError.videoUnavailable
        default:
            await emit(onProgress, "playabilityStatus=\(playerResponse.playabilityStatus.status) → videoUnavailable (unknown)")
            throw CaptionError.videoUnavailable
        }

        // 4. Extract caption tracks.
        guard let tracks = playerResponse.captions?
                .playerCaptionsTracklistRenderer?.captionTracks,
              !tracks.isEmpty else {
            await emit(onProgress, "no captionTracks → noCaptions")
            throw CaptionError.noCaptions
        }
        await emit(onProgress, "captionTracks: n=\(tracks.count)")

        // 5. Pick best English.
        guard let picked = pickBestEnglishCaptionTrack(tracks) else {
            await emit(onProgress, "no English track → noEnglishCaptions")
            throw CaptionError.noEnglishCaptions
        }
        await emit(onProgress, "picked \(picked.languageCode)\(picked.kind == "asr" ? " (ASR)" : " (manual)")")

        // 6. Fetch timedtext json3.
        let cues = try await fetchTimedtext(
            baseUrl: picked.baseUrl, fetcher: fetcher, onProgress: onProgress
        )

        // 7. Cache + return.
        cache.set(videoId, cues: cues)
        await emit(onProgress, "cache write")
        return cues
    }

    // MARK: - Private

    private static func fetchPlayerResponse(
        videoId: String,
        fetcher: HTTPFetcher
    ) async throws -> PlayerResponse {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.youtube/19.07.34 (Linux; U; Android 14) gzip",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("3", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("1.9", forHTTPHeaderField: "X-YouTube-Client-Version")

        // Innertube context — claims we're an Android YouTube app. The
        // server has no way to verify this without device attestation
        // which it doesn't enforce on the Android API path.
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID_TESTSUITE",
                    "clientVersion": "1.9",
                    "androidSdkVersion": 30,
                    "userAgent": "com.google.android.youtube/19.07.34 (Linux; U; Android 14) gzip",
                    "hl": "en",
                    "gl": "US",
                ],
            ],
            "videoId": videoId,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await fetcher(request)
        } catch let urlError as URLError {
            throw CaptionError.network(urlError)
        } catch {
            throw CaptionError.network(URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CaptionError.http(status: status)
        }

        do {
            return try JSONDecoder().decode(PlayerResponse.self, from: data)
        } catch {
            throw CaptionError.parseFailed
        }
    }

    private static func fetchTimedtext(
        baseUrl: String,
        fetcher: HTTPFetcher,
        onProgress: @MainActor @escaping (String) -> Void
    ) async throws -> [Cue] {
        // Append fmt=json3. baseUrl already carries the signed query
        // string YouTube minted for us — we never reach into it.
        guard var components = URLComponents(string: baseUrl) else {
            throw CaptionError.parseFailed
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "fmt", value: "json3"))
        components.queryItems = items
        guard let url = components.url else { throw CaptionError.parseFailed }

        await emit(onProgress, "GET timedtext")
        let request = URLRequest(url: url)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await fetcher(request)
        } catch let urlError as URLError {
            throw CaptionError.network(urlError)
        } catch {
            throw CaptionError.network(URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CaptionError.timedtextFetchFailed(status: status)
        }

        guard !data.isEmpty else { throw CaptionError.emptyResult }
        await emit(onProgress, "json3 body: len=\(data.count)")

        let spikeCues = parseTimedtextJson3(data)
        guard !spikeCues.isEmpty else { throw CaptionError.parseFailed }
        await emit(onProgress, "parsed: \(spikeCues.count) cues")

        // Map the parser's SpikeCue → app-wide Cue. translation /
        // highlights stay empty; AnalysisEngine fills them later.
        return spikeCues.map { spike in
            Cue(index: spike.idx, time: spike.time,
                endTime: spike.end, text: spike.text)
        }
    }

    private static func emit(
        _ onProgress: @MainActor @escaping (String) -> Void,
        _ message: String
    ) async {
        await MainActor.run { onProgress(message) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same xcodebuild command from Step 2.
Expected: 10 PASS.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Import/YouTubeCaptionExtractor.swift whatsub-mobileTests/YouTubeCaptionExtractorTests.swift
git commit -m "feat(import): YouTubeCaptionExtractor — pure-Swift Innertube client

Spec §4 implementation. Two HTTP calls (POST youtubei/v1/player as
ANDROID_TESTSUITE → GET timedtext fmt=json3), then SpikeCue → Cue map.

HTTPFetcher injection (typealias for @Sendable closure) lets tests
mock responses without network. Default is URLSession.shared.data(for:).
onProgress emits one log line per extraction step; ImportViewModel
will accumulate them for the 查看诊断 sheet.

Cache hits skip every HTTP call. Cache writes are best-effort (the
CaptionCache layer swallows write errors).

playabilityStatus mapping covers OK / LOGIN_REQUIRED /
AGE_VERIFICATION_REQUIRED / ERROR / UNPLAYABLE / LIVE_STREAM_OFFLINE
plus an unknown fallback that throws .videoUnavailable conservatively.

10 unit tests cover happy path, cache hit / write, every
CaptionError case, and the progress-event contract."
```

---

## Phase 3 — UI / VM integration

### Task 3.1: ImportViewModel — swap extractor, drop WebView state

**Files:**
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`

**Interfaces:**
- Consumes: `YouTubeCaptionExtractor.extract(...)` from Task 2.1
- Produces: No new public surface — internal refactor only. Same `.extractFailed(message:debug:)` state shape feeds ImportView unchanged.

- [ ] **Step 1: Inspect current state**

Run: `grep -n "CaptionExtractor\|liveWebView\|liveWebViewWatching" whatsub-mobile/Import/ImportViewModel.swift`

Expected output (current state from session context, prior to changes):
```
38:    @Published var liveWebView: WKWebView?
43:    @Published var liveWebViewWatching: Bool = false
88:        let extractor = CaptionExtractor()
89:        liveWebViewWatching = false
91:            cues = try await extractor.extract(
113:            liveWebView = nil  // teardown the host
114:            liveWebViewWatching = false
118:        liveWebView = nil
119:        liveWebViewWatching = false
```

(Numbers may shift; the named symbols are what matter.)

- [ ] **Step 2: Remove the WebView state + WebKit import**

Edit `whatsub-mobile/Import/ImportViewModel.swift` — at the top of the file:

Replace:
```swift
import Foundation
import WebKit
```

With:
```swift
import Foundation
```

Then delete the two `@Published` declarations (`liveWebView` and `liveWebViewWatching`) and their three doc-comment blocks. The block to remove begins with the comment `/// The hidden WKWebView used by CaptionExtractor` and ends after `@Published var liveWebViewWatching: Bool = false`.

- [ ] **Step 3: Replace the extract call**

In `run(urlOrId:)`, replace the existing block:

```swift
let extractor = CaptionExtractor()
liveWebViewWatching = false
do {
    cues = try await extractor.extract(
        videoId: resolvedId,
        onWebViewReady: { [weak self] web in
            self?.liveWebView = web
        },
        onWatchNavigation: { [weak self] in
            self?.liveWebViewWatching = true
        }
    )
} catch {
    state = .extractFailed(
        message: error.localizedDescription,
        debug: extractor.debugLog
    )
    liveWebView = nil  // teardown the host
    liveWebViewWatching = false
    return
}
// Success — drop the host so the WebView gets deallocated.
liveWebView = nil
liveWebViewWatching = false
```

With:

```swift
// 2026-06-19: switched to pure-Swift Innertube extractor (spec
// docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md).
// The new path doesn't use WKWebView, so the liveWebView state from
// the old flow is gone.
var debugLog: [String] = []
do {
    cues = try await YouTubeCaptionExtractor.extract(
        videoId: resolvedId,
        onProgress: { event in debugLog.append(event) }
    )
} catch {
    state = .extractFailed(
        message: error.localizedDescription,
        debug: debugLog
    )
    return
}
```

- [ ] **Step 4: Verify it builds**

Run: `xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (or a CI run that builds for sim — `gh run watch` after push works too).

If the build fails with "cannot find type 'CaptionExtractor'" or similar references in OTHER files (e.g., ImportView still references `vm.liveWebView`), DO NOT fix them here — they belong to Task 3.2 / Task 4.1. Verify the failure is confined to the next-task surface and proceed to commit.

- [ ] **Step 5: Commit**

```bash
git add whatsub-mobile/Import/ImportViewModel.swift
git commit -m "refactor(import): swap ImportViewModel to YouTubeCaptionExtractor

Removes liveWebView / liveWebViewWatching @Published state and the
WebKit import. Captions now come from the pure-Swift extractor
(spec §4); diagnostics accumulate into a local array passed to
.extractFailed as before, so ImportView.pushOfferBody works unchanged."
```

---

### Task 3.2: ImportView — drop WebView mount, simplify .extracting body

**Files:**
- Modify: `whatsub-mobile/Import/ImportView.swift`

**Interfaces:**
- Consumes: ImportViewModel state from Task 3.1 (no `liveWebView` / `liveWebViewWatching`)
- Produces: No new public surface

- [ ] **Step 1: Inspect current state**

Run: `grep -n "extractingBody\|liveWebView\|WKWebViewHost" whatsub-mobile/Import/ImportView.swift`

Expected to show:
- `case .extracting: extractingBody` in the state switch
- An `extractingBody` view that mounts `WKWebViewHost`
- Multiple `vm.liveWebView` and `vm.liveWebViewWatching` references inside `extractingBody`

- [ ] **Step 2: Rewrite extractingBody**

In `whatsub-mobile/Import/ImportView.swift`, locate the existing `extractingBody` private var (it currently wraps a `progressBody` plus a conditional `WKWebViewHost(webView: web)` mount). Replace the entire body, header docblock included, with:

```swift
// MARK: - Extracting (spinner only)

/// During native Innertube extraction (spec §7.1) there's nothing
/// visual to show — the network calls return in 1-3 seconds, often
/// faster than the user notices. A centred spinner + status line is
/// honest and avoids the previous WebView-mount-during-warmup UX
/// noise where users saw an unrelated YouTube homepage preview.
private var extractingBody: some View {
    VStack(spacing: 16) {
        Spacer()
        ProgressView()
            .tint(.whatsubAccent)
            .scaleEffect(1.2)
        Text("字幕提取中…")
            .font(.headline)
            .foregroundStyle(.whatsubInk)
        Text("通常 1-3 秒")
            .font(.subheadline)
            .foregroundStyle(.whatsubInkMuted)
        Spacer()
    }
    .padding()
}
```

- [ ] **Step 3: Verify it builds**

Run: `xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Build failures pointing at the legacy files (`CaptionExtractor.swift`, `CaptionHookJS.swift`, `WKWebViewHost.swift`) are expected and resolved in Task 4.1.

- [ ] **Step 4: Commit**

```bash
git add whatsub-mobile/Import/ImportView.swift
git commit -m "refactor(import): simplify ImportView.extractingBody (no WebView)

Spec §7.1 — the new pure-Swift extractor returns in 1-3 seconds; the
visible WKWebView mount the legacy path used (for IntersectionObserver
compliance + visual confirmation during warmup) is no longer needed.
A centred spinner + status line replaces it."
```

---

## Phase 4 — Cleanup

### Task 4.1: Delete the three WKWebView-path files

**Files:**
- Delete: `whatsub-mobile/Import/CaptionExtractor.swift`
- Delete: `whatsub-mobile/Import/CaptionHookJS.swift`
- Delete: `whatsub-mobile/Components/WKWebViewHost.swift`

**Interfaces:**
- Consumes: none
- Produces: smaller codebase (~600 LoC removed)

- [ ] **Step 1: Confirm no other references exist**

Run these greps and confirm each returns NO results:

```bash
grep -rn "CaptionExtractor" whatsub-mobile/ whatsub-mobileTests/ 2>&1 | grep -v "YouTubeCaptionExtractor"
grep -rn "CaptionHookJS" whatsub-mobile/ whatsub-mobileTests/
grep -rn "WKWebViewHost" whatsub-mobile/ whatsub-mobileTests/
```

If any reference remains (other than the YouTube extractor itself and its tests), open it and decide whether it's safe to drop. The expected remaining hits — all of them inside `whatsub-mobile/Import/YouTubeCaptionExtractor.swift` and its tests — refer to `YouTubeCaptionExtractor`, which the first grep's `grep -v` excludes.

- [ ] **Step 2: Delete the files**

```bash
rm whatsub-mobile/Import/CaptionExtractor.swift
rm whatsub-mobile/Import/CaptionHookJS.swift
rm whatsub-mobile/Components/WKWebViewHost.swift
```

- [ ] **Step 3: Verify full build**

Run: `xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify full test suite**

Run: `xcodebuild test -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10`
Expected: `Test Suite 'All tests' passed`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(import): delete WKWebView-path caption extractor

Removes the legacy 600 LoC that the pure-Swift Innertube extractor
(Task 2.1, spec §3) replaces:
  - CaptionExtractor.swift   — WKWebView orchestration + CheckedContinuation
  - CaptionHookJS.swift      — main-world JS injection + telemetry
  - WKWebViewHost.swift      — SwiftUI WebView mount

Diagnostics surface (CaptionDiagnosticsSheet) is unchanged; it now
displays the progress events emitted by the new extractor's
onProgress callback (Task 3.1).

Closes the WKWebView path. Revert with 'git revert' if Innertube
extraction proves unreliable on prod (spec §9.3)."
```

---

### Task 4.2: Optional MeView "清除字幕缓存" entry

**Files:**
- Modify: `whatsub-mobile/Me/MeView.swift`

**Interfaces:**
- Consumes: `CaptionCache.shared.clearAll()` from Task 1.2
- Produces: No new public surface

- [ ] **Step 1: Inspect existing 工具 section**

Run: `grep -n 'Section("工具")' whatsub-mobile/Me/MeView.swift`

You should find one occurrence. Read the surrounding 15-20 lines to understand the existing rows (e.g., `Button("AI 数据使用说明")` + a `NavigationLink` for 待同步暂存 if present).

- [ ] **Step 2: Add a cache-clear button**

Inside the existing `Section("工具")` block, after the last existing row (and before the closing brace), add:

```swift
Button("清除字幕缓存") {
    CaptionCache.shared.clearAll()
}
.foregroundStyle(.whatsubAccent)
```

Place it as the last button in the section so an accidental tap doesn't pre-empt other settings.

- [ ] **Step 3: Verify build**

Run: `xcodebuild -scheme whatsub-mobile -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add whatsub-mobile/Me/MeView.swift
git commit -m "feat(me): 清除字幕缓存 button under 工具

User-facing eviction path for CaptionCache (spec §5.3). Low-discovery
on purpose — the cache is permanent and most users won't ever need it;
power users who want to force a re-extract have an obvious knob."
```

---

## Phase 5 — Verification

### Task 5.1: Push + CI green + TestFlight delivers new build

**Files:** none (CI-driven)

**Interfaces:**
- Consumes: All previous commits
- Produces: confirmation the change builds + ships

- [ ] **Step 1: Push to main**

```bash
git push origin main
```

- [ ] **Step 2: Wait for CI**

```bash
gh run list --repo rjxznb/whatsub-mobile --limit 1 --workflow CI
# Note the run id and watch:
gh run watch <run-id> --repo rjxznb/whatsub-mobile --exit-status
```
Expected: `success`.

- [ ] **Step 3: Wait for TestFlight**

```bash
gh run list --repo rjxznb/whatsub-mobile --limit 1 --workflow TestFlight
gh run watch <run-id> --repo rjxznb/whatsub-mobile --exit-status
```
Expected: `success` and a new build delivered (~3-5 minutes after CI finishes).

If CI or TestFlight fails: read `gh run view <id> --log-failed`, identify the failure, fix in a follow-up commit. Common failures (per project's CLAUDE.md "踩过的坑" section):
- iOS SDK version mismatch — check `setup-xcode` step
- Distribution cert quota — manually revoke at developer.apple.com
- Apple PLA update required — accept at developer.apple.com

- [ ] **Step 4: No code change in this task — confirmation only**

No commit unless a fix is needed.

---

### Task 5.2: Manual integration test on real videos (USER)

**Files:** none (manual)

**Interfaces:**
- Consumes: TestFlight build from Task 5.1
- Produces: confirmation the pipeline works end-to-end on real YouTube content

- [ ] **Step 1: Install the new TestFlight build on a physical iPhone**

Open TestFlight → whatSub → Update.

- [ ] **Step 2: Verify 3 previously-failing video IDs now succeed**

Manually open the app's Library → + → paste each URL and confirm captions extract within ~3 seconds. The three video IDs that consistently failed against the WKWebView path are:

```
https://www.youtube.com/watch?v=G5wuhPjNfFI
https://www.youtube.com/watch?v=WgQI655FqtM
https://www.youtube.com/watch?v=H8eP99neOVs
```

Expected: each one shows the extract spinner briefly, then transitions to the preview state with cues visible.

If any fail, tap 「查看诊断」 — the diagnostic sheet now shows the progress events from `onProgress`. Capture the events and add them as a follow-up commit's bug report.

- [ ] **Step 3: Verify failure paths still work**

- A video with disabled captions (creator turned them off): expect `.noCaptions` message + "推送到桌面端" button.
- An age-restricted video: expect `.requiresLogin` message.

- [ ] **Step 4: Verify the cache hit path**

After extracting a video successfully, navigate away (close the import sheet), then re-open and try the same videoId. Expect: extraction completes essentially instantly (no perceivable spinner) — that's the cache hit.

- [ ] **Step 5: No commit unless a regression is found**

If a regression: capture the videoId + diagnostic sheet contents and open an issue. Otherwise, proceed to Task 5.3.

---

### Task 5.3: Update CLAUDE.md + memory

**Files:**
- Modify: `whatsub-mobile/CLAUDE.md`
- Create: `C:/Users/renjx/.claude/projects/C--Users-renjx-Desktop-whatsub-mobile/memory/project_innertube_captions.md`
- Modify: `C:/Users/renjx/.claude/projects/C--Users-renjx-Desktop-whatsub-mobile/memory/MEMORY.md`

**Interfaces:**
- Consumes: shipped feature
- Produces: documentation explaining the architecture for future maintainers

- [ ] **Step 1: Append to CLAUDE.md's "Post-v1 features shipped" section**

Add this paragraph in the existing list (similar style to the other post-v1 entries — `### iOS Native YouTube Caption Extraction via Innertube (2026-06-19)`):

```markdown
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
```

- [ ] **Step 2: Create the memory file**

Create `C:/Users/renjx/.claude/projects/C--Users-renjx-Desktop-whatsub-mobile/memory/project_innertube_captions.md`:

```markdown
---
name: project-innertube-captions
description: iOS native YouTube caption extractor via Innertube ANDROID_TESTSUITE — pure-Swift HTTP, bypasses BotGuard. Shipped 2026-06-19.
metadata:
  type: project
---

iOS-native YouTube caption extraction. **Why**: legacy WKWebView path
hit BotGuard / PO_TOKEN walls and capped at ~30% success rate. **How
to apply**: when YouTube changes anything caption-related, the first
look is `whatsub-mobile/Import/YouTubeCaptionExtractor.swift` — the
client context constants live at the top, the playabilityStatus
mapping is a single switch, and `pickBestEnglishCaptionTrack` is a
20-line function. ~150 LoC total, one file, one mental model.

Architecture: two HTTP calls — POST `youtubei/v1/player` claiming
ANDROID_TESTSUITE, GET timedtext with `fmt=json3`. The Android API
path has no BotGuard because Android native apps can't run JS
sandboxes; YouTube would have to add device attestation to enforce
it, which would break smart-TV ecosystem. Same trick NewPipe (1B+
users), Invidious, LibreTube, and yt-dlp use.

**Critical things to remember**:
- Client context is `ANDROID_TESTSUITE` + clientVersion `1.9`. When
  these stop working, mirror what yt-dlp's
  `extractor/youtube/_base.py` or NewPipe's `YoutubeParsingHelper.java`
  ship.
- Fallback context: `TV_EMBEDDED` with X-YouTube-Client-Name `85`.
- Cache lives at `~/Library/Caches/<bundle-id>/yt_captions/<videoId>.json`,
  one file per video, permanent (no TTL). User-driven clear via
  MeView's `清除字幕缓存` button or via `CaptionCache.shared.clearAll()`.
- Failure UX unchanged: `CaptionDiagnosticsSheet` shows `onProgress`
  events; failure messages route to "推送到桌面端" CTA.
- See [[reference_yt_botguard_path]] for the WKWebView path that this
  replaced (in case a future revert is needed).

Spec + plan: `docs/superpowers/{specs,plans}/2026-06-19-ios-innertube-captions*.md`.
```

- [ ] **Step 3: Add an index entry to MEMORY.md**

Append one line to `MEMORY.md` after the existing entries:

```markdown
- [iOS native YouTube caption extraction (Innertube)](project_innertube_captions.md) — pure-Swift HTTP via ANDROID_TESTSUITE,bypasses BotGuard。当 YT 又改字幕路径时第一看 `Import/YouTubeCaptionExtractor.swift` 的常量。2026-06-19 替换 WKWebView 路径
```

- [ ] **Step 4: Commit CLAUDE.md (memory is outside repo, no commit needed)**

```bash
git add whatsub-mobile/CLAUDE.md
git commit -m "docs(claude.md): document iOS native YouTube caption extraction

Phase 5 of docs/superpowers/plans/2026-06-19-ios-innertube-captions.md.
Captures the architecture, the ANDROID_TESTSUITE / TV_EMBEDDED
fallback, and what to look at first when YouTube changes things.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
git push origin main
```

---

## Self-Review

**Spec coverage (skim against `docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md`):**

- §2 decisions (replace, permanent cache, pure Swift, ANDROID_TESTSUITE, English-only, no flag): all baked into the plan's task scope, Cache TTL choice, and `clientName` constant.
- §3 file map: Tasks 1.1, 1.2, 1.3, 2.1 create the new files; Task 4.1 deletes the three legacy files; Tasks 3.1, 3.2, 4.2 modify ImportViewModel / ImportView / MeView respectively.
- §4 extraction flow: Task 2.1 implements every step (cache check, POST player, status map, captionTracks extract, pick English, GET timedtext, parse, cache write).
- §4.1 client context constants: copied verbatim into Task 2.1 implementation + Global Constraints section.
- §5 caching: Task 1.2 implements the per-video disk-cache shape including schema version.
- §6 error handling: Task 1.1 covers every case + message; Task 2.1 maps player responses to the right case.
- §7 UI changes: Task 3.2 simplifies extractingBody.
- §8 testing: Phase 1 + Phase 2 tasks each include unit tests with full code; Task 5.2 covers the manual integration test list.
- §9 rollout: Task 5.1 handles push + CI watch. Task 4.1's commit message references the revert path.
- §10 risks: Documented in Task 2.1 docblock + Task 5.3 docs entries.
- §11 non-goals: Reflected by the plan's absence of unrelated features.
- §12 estimate: Plan structure fits ~2 days when worked sequentially.

**Placeholder scan:** No "TBD", "TODO", "implement later" markers. Every step has executable content. Test code is verbatim and runnable.

**Type consistency:** 
- `Cue` (4-arg init) used consistently in Tasks 1.2, 2.1, 3.1.
- `SpikeCue` mentioned only as parseTimedtextJson3's return type — the extractor maps it to `Cue` before returning.
- `CaptionError` cases match across Tasks 1.1, 2.1, and the spec's §6.2 table.
- `HTTPFetcher` typealias defined in Task 2.1 and referenced consistently in Task 2.1's tests.
- Cache file format (`version`, `videoId`, `cachedAt`, `cues`) matches the spec §5.2 and the test in Task 1.2.
