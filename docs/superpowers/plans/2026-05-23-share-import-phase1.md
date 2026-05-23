# Share-to-Import Phase 1 (in-app YouTube import + client-side analysis) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** In-app import of a YouTube video (no share extension yet): paste/enter a YouTube URL → extract captions (the spike's validated WKWebView+hook, run headlessly) → client-side LLM analysis with the user's own openai-compatible key (bilingual + AI highlights + keyPhrases) → preview → "同步到云库" (existing `/api/library/sync`). Imported entries then read like synced ones.

**Architecture:** All client-side. Reuses the Phase-0 spike's `TimedtextParser` + `CaptionHookJS`. The LLM engine ports the plugin's `llm-core` analysis (prompts + batching + JSON-Lines parse) to Swift, using **non-streaming** `/chat/completions` per batch (simpler than the desktop's SSE streaming; a batch job with a progress bar). Backend unchanged.

**Tech Stack:** SwiftUI + WebKit + URLSession · XCTest. Provider: **openai-compatible only** (DeepSeek default).

**Spec:** `docs/superpowers/specs/2026-05-23-share-to-import-design.md`.
**Port references** (`C:\Users\renjx\Desktop\whatsub-plugin\packages\llm-core\src`): `prompts.ts`, `protocols/openaiCompatible.ts`, `protocols/types.ts`, `analyze.ts` (orchestration), `streamingJson.ts` (we replace with simple line-split since non-streaming).

**Reuses from spike (kept):** `whatsub-mobile/Import/TimedtextParser.swift` (SpikeCue + parseTimedtextJson3), `whatsub-mobile/Import/CaptionHookJS.swift`.

---

## File Structure

**Part A — LLM engine (unit-testable, no device)**
| File | Responsibility |
|---|---|
| `whatsub-mobile/LLM/LlmSettings.swift` | provider config struct (baseUrl/apiKey/model, default DeepSeek) + Keychain persistence |
| `whatsub-mobile/LLM/LlmSettingsView.swift` | settings form in 我的 tab |
| `whatsub-mobile/LLM/OpenAICompatibleClient.swift` | `chat(messages:) async throws -> String` (non-streaming /chat/completions) |
| `whatsub-mobile/LLM/AnalysisPrompts.swift` | the ported prompt strings (verbatim from plugin prompts.ts) |
| `whatsub-mobile/LLM/AnalysisEngine.swift` | batch cues → per-cue analysis + summary → assemble `AnalysisJson` (reuses the existing `Cue`/`AnalysisJson`/`KeyPhrase` DTOs) |
| `whatsub-mobileTests/AnalysisEngineTests.swift` | parse a JSON-Lines fixture → AnalysisJson; batching |

**Part B — import flow (device)**
| File | Responsibility |
|---|---|
| `whatsub-mobile/Import/CaptionExtractor.swift` | headless WKWebView (refit spike's capture) → `[SpikeCue]` via async/continuation + timeout |
| `whatsub-mobile/Import/ImportViewModel.swift` | orchestrate extract → analyze (progress) → hold result |
| `whatsub-mobile/Import/ImportView.swift` | URL field → run → progress → preview (reuse CueRow) → 同步 |
| `whatsub-mobile/Networking/WhatsubAPI.swift` | + `syncLibraryEntry(...)` → POST /api/library/sync |
| `whatsub-mobile/Networking/DTOs.swift` | + `SyncLibraryEntryRequest` (Encodable) |
| `whatsub-mobile/Me/MeView.swift` | replace the spike entry with a real "导入视频" entry + LLM 设置 entry; delete `CaptionSpikeView.swift` |

---

## Pre-flight
```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git checkout main && git pull && git checkout -b feat/ios-import-phase1
```

---

## PART A — LLM engine

### Task A1: LlmSettings + Keychain

**Files:** Create `whatsub-mobile/LLM/LlmSettings.swift`

- [ ] **Step 1:** 
```swift
import Foundation

/// openai-compatible LLM config (v1 supports only this provider). Default =
/// DeepSeek, matching the desktop's default openaiCompatible slot.
struct LlmSettings: Codable, Equatable {
    var baseUrl: String = "https://api.deepseek.com/v1"
    var apiKey: String = ""
    var model: String = "deepseek-chat"

    var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Persists LlmSettings in the Keychain (the apiKey is sensitive) under one item.
enum LlmSettingsStore {
    private static let service = "cc.eversay.whatsub.mobile.llm"
    private static let account = "llm-settings"

    static func load() -> LlmSettings {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = try? JSONDecoder().decode(LlmSettings.self, from: data) else {
            return LlmSettings()
        }
        return s
    }

    static func save(_ s: LlmSettings) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
```
- [ ] **Step 2:** Commit: `git add whatsub-mobile/LLM/LlmSettings.swift && git commit -m "feat(ios/llm): LlmSettings + Keychain store"`

### Task A2: OpenAICompatibleClient

**Files:** Create `whatsub-mobile/LLM/OpenAICompatibleClient.swift`

Port the request shape from `packages/llm-core/src/protocols/openaiCompatible.ts` but **non-streaming** (`stream:false`, read `choices[0].message.content`).

- [ ] **Step 1:**
```swift
import Foundation

struct ChatMessage { let role: String; let content: String }

/// Minimal non-streaming openai-compatible /chat/completions client.
/// (The desktop streams via SSE; for a batch import job we take the full
/// response — simpler + adequate behind a progress bar.)
struct OpenAICompatibleClient {
    let settings: LlmSettings

    func chat(_ messages: [ChatMessage]) async throws -> String {
        guard settings.isConfigured, let url = URL(string: "\(settings.baseUrl)/chat/completions") else {
            throw LlmError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "model": settings.model,
            "stream": false,
            "temperature": 0.3,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw LlmError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw LlmError.network("no http") }
        guard (200..<300).contains(http.statusCode) else {
            throw LlmError.api(http.statusCode, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LlmError.badResponse
        }
        return content
    }

    enum LlmError: Error, LocalizedError {
        case notConfigured, network(String), api(Int, String), badResponse
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "请先在「我的 → LLM 设置」填入 API Key"
            case .network(let d): return "网络失败：\(d)"
            case .api(let c, _): return "LLM 接口错误（\(c)）"
            case .badResponse: return "LLM 返回格式异常"
            }
        }
    }
}
```
- [ ] **Step 2:** Commit: `git add whatsub-mobile/LLM/OpenAICompatibleClient.swift && git commit -m "feat(ios/llm): openai-compatible chat client (non-streaming)"`

### Task A3: AnalysisPrompts (VERBATIM port)

**Files:** Create `whatsub-mobile/LLM/AnalysisPrompts.swift`

- [ ] **Step 1:** Open `C:\Users\renjx\Desktop\whatsub-plugin\packages\llm-core\src\prompts.ts`. Copy **VERBATIM** into Swift string constants (raw strings `#"""..."""#`), preserving every character (the prompt rules are load-bearing — do NOT paraphrase):
  - `SYSTEM_PROMPT_TEMPLATE` (lines ~78-140) → `AnalysisPrompts.systemTemplate`. Replace `{{STYLE_GUIDANCE}}` with the `colloquial` style block (read `STYLE_GUIDANCE.colloquial` from prompts.ts ~lines 1-63) inline — v1 fixes style = colloquial.
  - `buildUserPrompt` (lines ~142-150) → `func userPrompt(_ cues: [Cue]) -> String` (tab-separated `index<TAB>time<TAB>endTime<TAB>JSON-text`; use `String(format:"%.2f")` for times; JSON-encode text via JSONSerialization on `[text]` then strip, OR `"\"\(text.replacing("\"", with: "\\\""))\""`).
  - `buildSummaryPrompt` (lines ~171-205) → `func summaryPrompt(_ subs: [Cue]) -> String`. Read the full function in prompts.ts for the compact-form shape it sends.
```swift
import Foundation

enum AnalysisPrompts {
    // VERBATIM from llm-core/prompts.ts SYSTEM_PROMPT_TEMPLATE with
    // {{STYLE_GUIDANCE}} resolved to the `colloquial` block. Do not paraphrase.
    static let system = #"""
    <paste SYSTEM_PROMPT_TEMPLATE here, {{STYLE_GUIDANCE}} replaced with the colloquial block>
    """#

    static func userPrompt(_ cues: [Cue]) -> String {
        let lines = cues.map { c in
            let text = String(data: (try? JSONSerialization.data(withJSONObject: c.text, options: .fragmentsAllowed)) ?? Data(), encoding: .utf8) ?? "\"\(c.text)\""
            return "\(c.index)\t\(String(format: "%.2f", c.time))\t\(String(format: "%.2f", c.endTime))\t\(text)"
        }.joined(separator: "\n")
        return """
        Subtitle cues (tab-separated: index<TAB>start<TAB>end<TAB>JSON-encoded text):
        \(lines)

        Produce one JSON-line per cue in order. Per-cue lines ONLY — do NOT emit a summary line; the summary will be requested separately.
        """
    }

    static func summaryPrompt(_ subs: [Cue]) -> String {
        // <port buildSummaryPrompt from prompts.ts:171-205 — compact form of each
        //  cue (text + translation + highlightWords + keyNotes) + the ask for a
        //  single {"type":"summary","keyPhrases":[...]} line>
    }
}
```
(The summaryPrompt body MUST be ported from the real function — read prompts.ts:171-205 and reproduce its compact-cue formatting + instruction text.)
- [ ] **Step 2:** Commit: `git add whatsub-mobile/LLM/AnalysisPrompts.swift && git commit -m "feat(ios/llm): analysis prompts (ported verbatim from llm-core)"`

### Task A4: AnalysisEngine (batch + parse + assemble) — TDD

**Files:** Create `whatsub-mobile/LLM/AnalysisEngine.swift` + `whatsub-mobileTests/AnalysisEngineTests.swift`

The engine: split cues into batches of 50 → per batch, `client.chat([system, user])` → split response into lines → JSON-decode each line into a `Cue` (the existing DTO; the LLM emits the exact `{index,time,endTime,text,translation,isKeyPoint,highlightWords,keyNotes,highlightTranslations}` schema, which `Cue`'s lenient decoder already handles) → collect. Then one summary call → parse the `{"type":"summary","keyPhrases":[...]}` line → `[KeyPhrase]`. Assemble `AnalysisJson`.

- [ ] **Step 1: Failing test** — pure line-parsing (no network). Add a `parseCueLines(_:) -> [Cue]` + `parseSummaryLine(_:) -> [KeyPhrase]` as testable statics:
```swift
import XCTest
@testable import whatsub_mobile

final class AnalysisEngineTests: XCTestCase {
    func testParseCueLinesSkipsNonJSONAndSummary() {
        let raw = """
        {"type":"cue","index":0,"time":0,"endTime":1.6,"text":"Hi","translation":"嗨","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        garbage line
        {"type":"cue","index":1,"time":1.6,"endTime":3,"text":"Save up","translation":"攒钱","isKeyPoint":true,"highlightWords":["Save up"],"keyNotes":{"Save up":"攒钱的意思"},"highlightTranslations":{"Save up":"攒钱"}}
        """
        let cues = AnalysisEngine.parseCueLines(raw)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].translation, "攒钱")
        XCTAssertEqual(cues[1].highlightWords, ["Save up"])
    }
    func testParseSummaryLine() {
        let raw = #"{"type":"summary","keyPhrases":[{"expression":"save up","meaningZh":"攒钱","usage":"存钱"}]}"#
        let kp = AnalysisEngine.parseSummaryLine(raw)
        XCTAssertEqual(kp.first?.expression, "save up")
    }
    func testBatching() {
        let cues = (0..<120).map { i in cueFixture(index: i) }
        XCTAssertEqual(AnalysisEngine.batches(cues, size: 50).count, 3)
    }
}
// helper cueFixture(index:) builds a minimal Cue via JSON decode.
```
- [ ] **Step 2: Run → RED.**
- [ ] **Step 3: Implement `AnalysisEngine.swift`:**
```swift
import Foundation

struct AnalysisEngine {
    let client: OpenAICompatibleClient

    static func batches(_ cues: [Cue], size: Int = 50) -> [[Cue]] {
        stride(from: 0, to: cues.count, by: size).map { Array(cues[$0..<min($0+size, cues.count)]) }
    }

    /// Decode JSON-Lines per-cue output into Cue[]. Skips blank/non-JSON lines
    /// and any stray summary line. Reuses the existing tolerant `Cue` decoder.
    static func parseCueLines(_ raw: String) -> [Cue] {
        var out: [Cue] = []
        for line in raw.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("{"), let data = s.data(using: .utf8) else { continue }
            // skip summary lines
            if s.contains("\"type\":\"summary\"") || s.contains("\"keyPhrases\"") { continue }
            if let cue = try? JSONDecoder().decode(Cue.self, from: data) { out.append(cue) }
        }
        return out
    }

    static func parseSummaryLine(_ raw: String) -> [KeyPhrase] {
        for line in raw.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.contains("\"keyPhrases\""), let data = s.data(using: .utf8) else { continue }
            struct S: Decodable { let keyPhrases: [KeyPhrase] }
            if let parsed = try? JSONDecoder().decode(S.self, from: data) { return parsed.keyPhrases }
        }
        return []
    }

    /// Full analysis. `onProgress(done, total)` for the UI.
    func analyze(_ cues: [Cue], onProgress: @escaping (Int, Int) -> Void) async throws -> AnalysisJson {
        let batched = Self.batches(cues)
        var subtitles: [Cue] = []
        for (i, batch) in batched.enumerated() {
            let content = try await client.chat([
                ChatMessage(role: "system", content: AnalysisPrompts.system),
                ChatMessage(role: "user", content: AnalysisPrompts.userPrompt(batch)),
            ])
            subtitles.append(contentsOf: Self.parseCueLines(content))
            onProgress(i + 1, batched.count + 1)
        }
        // Re-index sequentially (LLM should preserve, but be safe).
        for i in subtitles.indices { subtitles[i].index = i }
        // Summary (keyPhrases).
        var keyPhrases: [KeyPhrase] = []
        if !subtitles.isEmpty {
            let summary = try await client.chat([
                ChatMessage(role: "system", content: AnalysisPrompts.system),
                ChatMessage(role: "user", content: AnalysisPrompts.summaryPrompt(subtitles)),
            ])
            keyPhrases = Self.parseSummaryLine(summary)
        }
        onProgress(batched.count + 1, batched.count + 1)
        return AnalysisJson.assembled(subtitles: subtitles, keyPhrases: keyPhrases)
    }
}
```
(NOTE: `AnalysisJson`/`Cue`/`KeyPhrase` currently only have `Decodable`. Add a memberwise `AnalysisJson.assembled(subtitles:keyPhrases:)` factory in DTOs.swift since the JSON `init(from:)` can't be used to construct from parts. Also `Cue.index` is `var` — settable — good.)
- [ ] **Step 4: Run → GREEN.** Commit: `git add whatsub-mobile/LLM/AnalysisEngine.swift whatsub-mobileTests/AnalysisEngineTests.swift whatsub-mobile/Networking/DTOs.swift && git commit -m "feat(ios/llm): AnalysisEngine batch+parse+assemble + TDD"`

### Task A5: LlmSettingsView

**Files:** Create `whatsub-mobile/LLM/LlmSettingsView.swift`

- [ ] **Step 1:** A `Form` with baseUrl/apiKey(SecureField)/model + Save (writes `LlmSettingsStore.save`). Loads on appear. Brand-themed. Reachable from MeView (Task B5). Commit.

---

## PART B — import flow (device)

### Task B1: CaptionExtractor (headless capture)

**Files:** Create `whatsub-mobile/Import/CaptionExtractor.swift`

Refit the spike's `CaptionCaptureWebView` into a headless async API: load the watch page (cc_load_policy=1) in an off-screen WKWebView with the hook, await the first captured timedtext (or time out ~20s), parse → `[SpikeCue]`. Map `SpikeCue` → `Cue` (via `AnalysisJson` building or a small adapter: SpikeCue.text→Cue.text, time, end→endTime; translation/highlights empty until analysis).

- [ ] **Step 1:** Implement an `actor`/class with `func extract(videoId: String) async throws -> [Cue]` using a `CheckedContinuation` resumed by the WKScriptMessageHandler (first non-empty parse) + a timeout Task. Reuse `CaptionHookJS.source` + `parseTimedtextJson3`. Keep the WKWebView retained for the duration. Map cues to the `Cue` DTO (index/time/endTime/text; empty translation/highlights). Commit.

### Task B2: WhatsubAPI.syncLibraryEntry + DTO

**Files:** Modify `whatsub-mobile/Networking/WhatsubAPI.swift` + `DTOs.swift`

- [ ] **Step 1:** `DTOs.swift`: `struct SyncLibraryEntryRequest: Encodable { id, youtubeId, sourceUrl, title, durationSec, thumbUrl, transcriptSrt, analysisJson }` where analysisJson is encoded from the assembled result (encode `AnalysisJson` — needs `Encodable`; add `Encodable` conformance producing the backend schema, OR build a `[String:Any]` and post raw). Simplest: build the JSON body as `[String:Any]` in the API method.
- [ ] **Step 2:** `WhatsubAPI`: `func syncLibraryEntry(id:youtubeId:sourceUrl:title:durationSec:transcriptSrt:analysisJson:token:) async throws` → `postExpectingOk(Endpoints.library("sync"), body:..., bearer: token)`. Build `analysisJson` as a nested dict (subtitles + keyPhrases) so it round-trips to the backend's expected shape. Commit.

### Task B3: ImportViewModel

**Files:** Create `whatsub-mobile/Import/ImportViewModel.swift`

- [ ] **Step 1:** `@MainActor` VM: `state` enum (idle/extracting/analyzing(done,total)/preview/syncing/done/error), `extractAndAnalyze(url:)` (extractYouTubeID → CaptionExtractor.extract → AnalysisEngine.analyze with progress → hold `AnalysisJson` + title), `sync(token:)` (build SRT from cues, call syncLibraryEntry). Uses `extractYouTubeID` (exists from corpus). Title: fetch from the watch page `<title>` or use the videoId as fallback (v1: videoId fallback ok). Commit.

### Task B4: ImportView

**Files:** Create `whatsub-mobile/Import/ImportView.swift`

- [ ] **Step 1:** URL/ID `TextField` + "解析导入" button → progress (extracting / analyzing N/total) → preview (a `ScrollView` of `CueRow` over the result's subtitles, reusing the existing CueRow + splitForHighlights) → "同步到云库" button (calls vm.sync, then a success toast + dismiss). VPN hint near the button ("解析需挂 VPN 连 YouTube"). Brand-themed. Commit.

### Task B5: Wire into 我的 + remove spike

**Files:** Modify `whatsub-mobile/Me/MeView.swift`; delete `whatsub-mobile/Import/CaptionSpikeView.swift`

- [ ] **Step 1:** Replace the temp "🧪 字幕提取 spike" entry with two real entries: NavigationLinks to `ImportView()` ("导入 YouTube 视频") and `LlmSettingsView()` ("LLM 设置"). `rm whatsub-mobile/Import/CaptionSpikeView.swift`. Commit.

### Task B6: Push + CI
- [ ] Push `feat/ios-import-phase1`; watch CI (build + AnalysisEngineTests + TimedtextParserTests). Fix compile errors, re-push until green.

### Task B7: Merge + TestFlight — PAUSE for user
- [ ] **STOP. Get authorization** (TestFlight + cert slots). Then user (VPN on): 我的 → LLM 设置 (enter DeepSeek key) → 导入 YouTube 视频 → paste a captioned URL → watch extract+analyze progress → preview bilingual+highlights → 同步 → appears in Library tab.

---

## Self-review checklist (for the controller before dispatch)
- A3 prompts MUST be copied verbatim from prompts.ts (quality-critical) — instruct the implementer to read the file, not retype from memory.
- `AnalysisJson.assembled(...)` factory added (DTOs only have Decodable today).
- `Cue` reused as the LLM per-cue output type (its tolerant decoder already handles keyNotes-as-object); `Cue.index` is settable.
- CaptionExtractor maps SpikeCue→Cue; analysis fills translation/highlights.
- Spike UI removed; TimedtextParser + CaptionHookJS kept.

## Done criteria
- 我的 → 导入 YouTube 视频 → URL → (VPN) extract captions → client-side LLM analysis (user's key) → bilingual + highlighted preview → 同步到云库 → shows in Library tab + reads like a synced entry.
- LLM settings persist (Keychain). AnalysisEngine unit tests green. CI green. TestFlight build works end-to-end.

## Out of scope (later phases)
- Share Extension (Phase 2). Bilibili (Phase 3). Claude/Gemini providers. Streaming/live progress. whisper fallback. Title scrape refinement.
