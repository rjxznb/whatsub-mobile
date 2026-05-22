# Plan 2 Phase 2c: iOS Library List + Detail (bilingual subtitle reader)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** The Library tab fetches cloud-synced entries (`/api/library/list`), shows them as a list with pull-to-refresh, and on tap opens a detail view: embedded YouTube player (top) + scrolling bilingual subtitles (English + Chinese, AI-highlighted phrases). Subtitles follow playback (auto-scroll + highlight current cue); tapping a cue seeks the player; tapping a highlighted phrase shows its meaning. Portrait = split (player top / subtitles below); landscape = subtitles overlaid under the player.

**Architecture:** `WhatsubAPI` gains `listLibrary` + `libraryEntry`. The detail entry's `analysisJson` decodes to `{ subtitles: [Cue], keyPhrases: [...] }` — each Cue already carries English `text`, Chinese `translation`, timing, and `highlightWords` + `keyNotes`. **No SRT parsing needed** — render straight from `analysisJson.subtitles`. YouTube embed = `WKWebView` loading the IFrame Player API with a JS↔Swift bridge (Swift→JS `seekTo`; JS→Swift `onTimeUpdate` every 250ms). Highlight runs computed by a Swift port of the desktop's `splitForHighlights`.

**Tech Stack:** SwiftUI · WKWebView (UIViewRepresentable) · WKScriptMessageHandler bridge · async/await · XCTest.

**Working dir:** `C:\Users\renjx\Desktop\whatsub-mobile`.

**Backend (live):** `GET /api/library/list` → `{entries:[{id,youtubeId,sourceUrl,title,durationSec,thumbUrl,syncedAt}]}`; `GET /api/library/entry/:id` → full entry incl `transcriptSrt` + `analysisJson`. Both Bearer-session-auth.

**analysisJson shape** (verbatim from desktop `AnalysisResult`, confirmed by reading `client/src/llm/types.ts`):
```json
{
  "subtitles": [
    { "time": 0.0, "endTime": 2.5, "text": "English.", "translation": "中文。",
      "isKeyPoint": false, "highlightWords": ["phrase"],
      "keyNotes": {"phrase": "解释"}, "highlightTranslations": {"phrase": "翻译"} }
  ],
  "keyPhrases": [ { "expression": "...", "meaningZh": "...", "usage": "..." } ]
}
```

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `whatsub-mobile/Networking/DTOs.swift` | + library DTOs (LibraryListItem, LibraryEntryDetail, AnalysisJson, Cue, KeyPhrase) | Modify |
| `whatsub-mobile/Networking/WhatsubAPI.swift` | + `listLibrary(token:)` + `libraryEntry(id:token:)` | Modify |
| `whatsub-mobile/Library/LibraryViewModel.swift` | fetch list + state | Create |
| `whatsub-mobile/Library/LibraryView.swift` | list + pull-to-refresh + nav to detail (replaces LibraryPlaceholderView) | Create |
| `whatsub-mobile/Library/Highlighting.swift` | `splitForHighlights` Swift port + AttributedString builder | Create |
| `whatsub-mobile/Library/LibraryDetailViewModel.swift` | load entry, hold cues + current index | Create |
| `whatsub-mobile/Library/LibraryDetailView.swift` | player + subtitle scroll, portrait/landscape | Create |
| `whatsub-mobile/Library/CueRow.swift` | one subtitle row (En highlighted + Zh + tap) | Create |
| `whatsub-mobile/Components/YouTubeEmbedView.swift` | WKWebView IFrame player + JS bridge | Create |
| `whatsub-mobile/App/WhatsubMobileApp.swift` | tab 0 → LibraryView (was LibraryPlaceholderView) | Modify |
| `whatsub-mobile/Views/LibraryPlaceholderView.swift` | delete (unused after swap) | Delete |
| `whatsub-mobileTests/HighlightingTests.swift` | splitForHighlights cases | Create |
| `whatsub-mobileTests/AnalysisDecodeTests.swift` | decode analysisJson → cues | Create |

---

## Pre-flight

- [ ] **Branch + confirm main is current (Plan 2a merged)**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git checkout main && git pull
git checkout -b feat/ios-phase2c-library
```

No local Swift compile (no Mac) — verification is the CI run after pushing the branch (build + tests + screenshot). Commit per task; push the branch near the end to let CI validate before merge.

---

### Task 1: Library DTOs

**Files:** Modify `whatsub-mobile/Networking/DTOs.swift` (append)

- [ ] **Step 1: Append the library DTOs**

```swift

// ----- Library -----

struct LibraryListItem: Decodable, Identifiable {
    let id: String
    let youtubeId: String
    let sourceUrl: String
    let title: String
    let durationSec: Int?
    let thumbUrl: String?
    let syncedAt: Int64
}

struct LibraryListResponse: Decodable {
    let entries: [LibraryListItem]
}

/// One subtitle cue from analysisJson.subtitles — already bilingual + highlighted.
struct Cue: Decodable, Identifiable {
    var id: Int { index }
    /// Synthesized at decode time (array position) since the JSON has no id.
    var index: Int = 0

    let time: Double
    let endTime: Double
    let text: String          // English
    let translation: String   // Chinese
    let isKeyPoint: Bool
    let highlightWords: [String]
    let keyNotes: [String: String]
    let highlightTranslations: [String: String]

    enum CodingKeys: String, CodingKey {
        case time, endTime, text, translation, isKeyPoint
        case highlightWords, keyNotes, highlightTranslations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
        endTime = try c.decodeIfPresent(Double.self, forKey: .endTime) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        isKeyPoint = try c.decodeIfPresent(Bool.self, forKey: .isKeyPoint) ?? false
        highlightWords = try c.decodeIfPresent([String].self, forKey: .highlightWords) ?? []
        keyNotes = try c.decodeIfPresent([String: String].self, forKey: .keyNotes) ?? [:]
        highlightTranslations = try c.decodeIfPresent([String: String].self, forKey: .highlightTranslations) ?? [:]
    }
}

struct KeyPhrase: Decodable {
    let expression: String
    let meaningZh: String
    let usage: String
}

struct AnalysisJson: Decodable {
    let subtitles: [Cue]
    let keyPhrases: [KeyPhrase]

    enum CodingKeys: String, CodingKey { case subtitles, keyPhrases }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var subs = try c.decodeIfPresent([Cue].self, forKey: .subtitles) ?? []
        // Synthesize stable indices (JSON cues have no id).
        for i in subs.indices { subs[i].index = i }
        subtitles = subs
        keyPhrases = try c.decodeIfPresent([KeyPhrase].self, forKey: .keyPhrases) ?? []
    }
}

struct LibraryEntryDetail: Decodable {
    let id: String
    let youtubeId: String
    let title: String
    let durationSec: Int?
    let transcriptSrt: String?
    let analysisJson: AnalysisJson
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Networking/DTOs.swift
git commit -m "feat(ios/library): list + detail + analysisJson DTOs"
```

---

### Task 2: WhatsubAPI library methods

**Files:** Modify `whatsub-mobile/Networking/WhatsubAPI.swift`

- [ ] **Step 1: Add methods after the auth methods**

```swift
    // ----- Library -----

    func listLibrary(token: String) async throws -> [LibraryListItem] {
        let data = try await get(Endpoints.library("list"), bearer: token)
        return try decode(LibraryListResponse.self, from: data).entries
    }

    func libraryEntry(id: String, token: String) async throws -> LibraryEntryDetail {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await get(Endpoints.library("entry/\(encoded)"), bearer: token)
        return try decode(LibraryEntryDetail.self, from: data)
    }
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Networking/WhatsubAPI.swift
git commit -m "feat(ios/library): WhatsubAPI listLibrary + libraryEntry"
```

---

### Task 3: LibraryViewModel + LibraryView (list + pull-to-refresh)

**Files:** Create `whatsub-mobile/Library/LibraryViewModel.swift` + `whatsub-mobile/Library/LibraryView.swift`

- [ ] **Step 1: LibraryViewModel.swift**

```swift
import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryListItem] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var loadedOnce = false

    func load(token: String) async {
        loading = true
        errorMessage = nil
        do {
            entries = try await WhatsubAPI.shared.listLibrary(token: token)
        } catch APIError.unauthorized {
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败，请下拉重试"
        }
        loading = false
        loadedOnce = true
    }
}
```

- [ ] **Step 2: LibraryView.swift**

```swift
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                content
            }
            .navigationTitle("Library")
            .task { if !vm.loadedOnce { await reload() } }
            .refreshable { await reload() }   // pull-to-refresh
        }
    }

    private func reload() async {
        guard let token = appState.session?.sessionToken else { return }
        await vm.load(token: token)
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.entries.isEmpty {
            ProgressView().tint(.whatsubAccent)
        } else if let err = vm.errorMessage, vm.entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.whatsubInkMuted)
                Text(err).font(.callout).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
                Text("下拉重试").font(.footnote).foregroundStyle(.whatsubInkFaint)
            }.padding(32)
        } else if vm.entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle").font(.system(size: 48)).foregroundStyle(.whatsubAccent)
                Text("还没有同步的视频").font(.headline).foregroundStyle(.whatsubInk)
                Text("在桌面端 whatSub 的视频卡片上点 ☁️ 同步到云，\n这里下拉刷新就能看到").font(.footnote)
                    .foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
            }.padding(32)
        } else {
            List(vm.entries) { entry in
                NavigationLink(value: entry.id) {
                    LibraryRow(entry: entry)
                }
                .listRowBackground(Color.whatsubBgElev)
            }
            .scrollContentBackground(.hidden)
            .navigationDestination(for: String.self) { id in
                LibraryDetailView(entryId: id)
            }
        }
    }
}

private struct LibraryRow: View {
    let entry: LibraryListItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.thumbUrl.flatMap(URL.init)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.whatsubBgSoft
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.subheadline).foregroundStyle(.whatsubInk).lineLimit(2)
                Text(durationText).font(.caption).foregroundStyle(.whatsubInkMuted)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var durationText: String {
        guard let s = entry.durationSec else { return "" }
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Library/LibraryViewModel.swift whatsub-mobile/Library/LibraryView.swift
git commit -m "feat(ios/library): LibraryView list + pull-to-refresh + states"
```

---

### Task 4: Wire LibraryView into the tab

**Files:** Modify `whatsub-mobile/App/WhatsubMobileApp.swift`; Delete `whatsub-mobile/Views/LibraryPlaceholderView.swift`

- [ ] **Step 1: Replace `LibraryPlaceholderView()` with `LibraryView()`** in the TabView (tab tag 0). Leave CorpusPlaceholderView (Phase 2b).

- [ ] **Step 2: Delete the placeholder**

```bash
rm whatsub-mobile/Views/LibraryPlaceholderView.swift
```

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/App/WhatsubMobileApp.swift whatsub-mobile/Views/LibraryPlaceholderView.swift
git commit -m "feat(ios/library): tab 0 uses real LibraryView"
```

---

### Task 5: Highlighting (splitForHighlights port + tests)

**Files:** Create `whatsub-mobile/Library/Highlighting.swift` + `whatsub-mobileTests/HighlightingTests.swift`

- [ ] **Step 1: Write failing test**

`whatsub-mobileTests/HighlightingTests.swift`:

```swift
import XCTest
@testable import whatsub_mobile

final class HighlightingTests: XCTestCase {
    func testNoHighlights() {
        let runs = splitForHighlights("hello world", highlights: [])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "hello world")
        XCTAssertFalse(runs[0].highlight)
    }

    func testSingleHighlight() {
        let runs = splitForHighlights("save up money now", highlights: ["save up"])
        // ["save up"(hl), " money now"(normal)]
        XCTAssertEqual(runs.map(\.text), ["save up", " money now"])
        XCTAssertEqual(runs.map(\.highlight), [true, false])
    }

    func testMiddleHighlight() {
        let runs = splitForHighlights("I really need it", highlights: ["really need"])
        XCTAssertEqual(runs.map(\.text), ["I ", "really need", " it"])
        XCTAssertEqual(runs.map(\.highlight), [false, true, false])
    }

    func testNonOverlappingEarliestWins() {
        // "abc" and "bcd" overlap; earliest-start ("abc") wins, "bcd" dropped.
        let runs = splitForHighlights("abcde", highlights: ["abc", "bcd"])
        XCTAssertEqual(runs.map(\.text), ["abc", "de"])
        XCTAssertEqual(runs.map(\.highlight), [true, false])
    }

    func testMissingHighlightIgnored() {
        let runs = splitForHighlights("hello", highlights: ["xyz"])
        XCTAssertEqual(runs.map(\.text), ["hello"])
        XCTAssertEqual(runs.map(\.highlight), [false])
    }
}
```

- [ ] **Step 2: Run, verify RED** (function not defined) — deferred to CI; locally just confirm the file references `splitForHighlights`.

- [ ] **Step 3: Implement `Highlighting.swift`** (port of desktop `splitForHighlights`)

```swift
import Foundation

struct HighlightRun: Equatable {
    let text: String
    let highlight: Bool
}

/// Slice `text` into runs alternating normal / highlight. Non-overlapping —
/// earliest-start highlight wins on collisions. Byte-for-byte port of the
/// desktop client's splitForHighlights (client/src/components/VideoPlayer.tsx)
/// so iOS highlights match the desktop exactly.
func splitForHighlights(_ text: String, highlights: [String]) -> [HighlightRun] {
    let nonEmpty = highlights.filter { !$0.isEmpty }
    if nonEmpty.isEmpty { return [HighlightRun(text: text, highlight: false)] }

    let chars = Array(text)
    struct Match { let start: Int; let end: Int }
    var matches: [Match] = []
    for w in nonEmpty {
        if let range = text.range(of: w) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            matches.append(Match(start: start, end: end))
        }
    }
    matches.sort { $0.start < $1.start }
    var merged: [Match] = []
    var lastEnd = 0
    for m in matches where m.start >= lastEnd {
        merged.append(m); lastEnd = m.end
    }
    var runs: [HighlightRun] = []
    var cursor = 0
    for m in merged {
        if m.start > cursor {
            runs.append(HighlightRun(text: String(chars[cursor..<m.start]), highlight: false))
        }
        runs.append(HighlightRun(text: String(chars[m.start..<m.end]), highlight: true))
        cursor = m.end
    }
    if cursor < chars.count {
        runs.append(HighlightRun(text: String(chars[cursor...]), highlight: false))
    }
    return runs
}
```

(Note: desktop uses JS `indexOf` + `slice` which are UTF-16-based; Swift `range(of:)` + Character array are grapheme-based. For English subtitle text these agree. Edge cases with emoji could differ but subtitle text is plain English.)

- [ ] **Step 4: Commit**

```bash
git add whatsub-mobile/Library/Highlighting.swift whatsub-mobileTests/HighlightingTests.swift
git commit -m "feat(ios/library): splitForHighlights port + TDD"
```

---

### Task 6: AnalysisJson decode test

**Files:** Create `whatsub-mobileTests/AnalysisDecodeTests.swift`

- [ ] **Step 1: Write test**

```swift
import XCTest
@testable import whatsub_mobile

final class AnalysisDecodeTests: XCTestCase {
    func testDecodeAnalysisWithCues() throws {
        let json = #"""
        {"subtitles":[
          {"time":0.0,"endTime":2.5,"text":"Hello there.","translation":"你好。","isKeyPoint":false,"highlightWords":["Hello"],"keyNotes":{"Hello":"问候"},"highlightTranslations":{"Hello":"你好"}},
          {"time":2.5,"endTime":5.0,"text":"Save up money.","translation":"攒钱。","isKeyPoint":true,"highlightWords":["Save up"],"keyNotes":{},"highlightTranslations":{}}
        ],"keyPhrases":[{"expression":"save up","meaningZh":"攒钱","usage":"存钱以备将来"}]}
        """#.data(using: .utf8)!
        let a = try JSONDecoder().decode(AnalysisJson.self, from: json)
        XCTAssertEqual(a.subtitles.count, 2)
        XCTAssertEqual(a.subtitles[0].index, 0)
        XCTAssertEqual(a.subtitles[1].index, 1)
        XCTAssertEqual(a.subtitles[0].text, "Hello there.")
        XCTAssertEqual(a.subtitles[0].translation, "你好。")
        XCTAssertEqual(a.subtitles[0].highlightWords, ["Hello"])
        XCTAssertEqual(a.subtitles[0].keyNotes["Hello"], "问候")
        XCTAssertEqual(a.keyPhrases.first?.expression, "save up")
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        let json = #"{"subtitles":[{"time":1,"endTime":2,"text":"Hi","translation":"嗨"}],"keyPhrases":[]}"#.data(using: .utf8)!
        let a = try JSONDecoder().decode(AnalysisJson.self, from: json)
        XCTAssertEqual(a.subtitles[0].highlightWords, [])
        XCTAssertFalse(a.subtitles[0].isKeyPoint)
    }
}
```

- [ ] **Step 2: Commit** (implementation already done in Task 1's Cue/AnalysisJson decoders)

```bash
git add whatsub-mobileTests/AnalysisDecodeTests.swift
git commit -m "test(ios/library): analysisJson decode (cues + tolerant optionals)"
```

---

### Task 7: YouTubeEmbedView (WKWebView + JS bridge)

**Files:** Create `whatsub-mobile/Components/YouTubeEmbedView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import WebKit

/// A seek request from SwiftUI → the embedded player. `nonce` forces SwiftUI
/// to treat repeated seeks to the same second as distinct (so updateUIView fires).
struct SeekRequest: Equatable {
    let seconds: Double
    let nonce: UUID
}

/// Embeds a YouTube video via the official IFrame Player API in a WKWebView.
/// Bridge: Swift→JS `player.seekTo`; JS→Swift current time every 250ms via
/// `window.webkit.messageHandlers.iosBridge.postMessage`.
struct YouTubeEmbedView: UIViewRepresentable {
    let videoId: String
    var seek: SeekRequest?
    /// Called ~4x/sec with the player's current time (seconds).
    var onTime: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTime: onTime) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "iosBridge")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.loadHTMLString(Self.html(videoId: videoId), baseURL: URL(string: "https://www.youtube-nocookie.com"))
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let seek, seek != context.coordinator.lastSeek else { return }
        context.coordinator.lastSeek = seek
        let js = "if (window.player && window.player.seekTo) { window.player.seekTo(\(seek.seconds), true); window.player.playVideo(); }"
        webView.evaluateJavaScript(js)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onTime: (Double) -> Void
        weak var webView: WKWebView?
        var lastSeek: SeekRequest?
        init(onTime: @escaping (Double) -> Void) { self.onTime = onTime }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "iosBridge",
                  let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String, type == "time",
                  let sec = dict["sec"] as? Double else { return }
            onTime(sec)
        }
    }

    private static func html(videoId: String) -> String {
        """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;background:#000;height:100%;overflow:hidden}#player{width:100%;height:100%}</style></head>
        <body><div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          window.player = null;
          function onYouTubeIframeAPIReady() {
            window.player = new YT.Player('player', {
              videoId: '\(videoId)',
              host: 'https://www.youtube-nocookie.com',
              playerVars: { playsinline: 1, modestbranding: 1, rel: 0 },
              events: {
                onReady: function() {
                  setInterval(function() {
                    if (window.player && window.player.getCurrentTime) {
                      try {
                        window.webkit.messageHandlers.iosBridge.postMessage(
                          { type: 'time', sec: window.player.getCurrentTime() });
                      } catch (e) {}
                    }
                  }, 250);
                }
              }
            });
          }
        </script></body></html>
        """
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Components/YouTubeEmbedView.swift
git commit -m "feat(ios/library): YouTubeEmbedView WKWebView IFrame bridge"
```

---

### Task 8: CueRow (one subtitle row)

**Files:** Create `whatsub-mobile/Library/CueRow.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool
    let onTapCue: () -> Void
    let onTapHighlight: (_ word: String, _ note: String?, _ translation: String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            englishLine
            Text(cue.translation)
                .font(.system(size: 16))
                .foregroundStyle(isCurrent ? .whatsubInkSoft : .whatsubInkMuted)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.whatsubAccent.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onTapCue() }
    }

    private var englishLine: some View {
        // Build wrapped runs as a flow of tappable Text. For simplicity + reliable
        // wrapping, compose one Text with AttributedString for non-tappable display,
        // and overlay tap handling via a separate runs row when highlights exist.
        let runs = splitForHighlights(cue.text, highlights: cue.highlightWords)
        return runs.reduce(Text("")) { acc, run in
            if run.highlight {
                return acc + Text(run.text)
                    .foregroundColor(.whatsubHighlight)
                    .underline()
                    .fontWeight(.semibold)
            } else {
                return acc + Text(run.text).foregroundColor(isCurrent ? .whatsubInk : .whatsubInkSoft)
            }
        }
        .font(.system(size: 22))
        // Tap on the whole English line: if it has exactly the tapped highlight,
        // surface the first highlight's note. (Per-word hit-testing inside a
        // concatenated Text isn't supported by SwiftUI; we approximate by
        // showing the first highlight on a long-press. Cue tap = seek.)
        .onLongPressGesture {
            if let first = cue.highlightWords.first {
                onTapHighlight(first, cue.keyNotes[first], cue.highlightTranslations[first])
            }
        }
    }
}
```

(Note for implementer: SwiftUI `Text` concatenation can't hit-test individual runs. v1 approach: cue tap = seek; long-press = show first highlight's note popup. If per-word tap is wanted later, switch English line to a wrapping layout of individual tappable `Text` views — defer to a future task; YAGNI for now.)

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Library/CueRow.swift
git commit -m "feat(ios/library): CueRow — bilingual + highlight runs"
```

---

### Task 9: LibraryDetailViewModel

**Files:** Create `whatsub-mobile/Library/LibraryDetailViewModel.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import SwiftUI

@MainActor
final class LibraryDetailViewModel: ObservableObject {
    @Published var entry: LibraryEntryDetail?
    @Published var loading = true
    @Published var errorMessage: String?
    @Published var currentIndex: Int?
    @Published var seek: SeekRequest?

    // Popup for a tapped highlight.
    @Published var popupWord: String?
    @Published var popupNote: String?
    @Published var popupTranslation: String?
    @Published var showPopup = false

    private var cues: [Cue] { entry?.analysisJson.subtitles ?? [] }

    func load(id: String, token: String) async {
        loading = true; errorMessage = nil
        do {
            entry = try await WhatsubAPI.shared.libraryEntry(id: id, token: token)
        } catch APIError.unauthorized {
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败"
        }
        loading = false
    }

    /// Called by the player bridge ~4x/sec. Updates currentIndex when the
    /// playhead crosses into a new cue.
    func onPlayerTime(_ sec: Double) {
        let cs = cues
        guard !cs.isEmpty else { return }
        // Linear scan is fine (a few hundred cues); could binary-search later.
        let idx = cs.lastIndex(where: { $0.time <= sec + 0.05 })
        if idx != currentIndex { currentIndex = idx }
    }

    func seekTo(_ cue: Cue) {
        seek = SeekRequest(seconds: cue.time, nonce: UUID())
    }

    func showHighlight(word: String, note: String?, translation: String?) {
        popupWord = word; popupNote = note; popupTranslation = translation; showPopup = true
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Library/LibraryDetailViewModel.swift
git commit -m "feat(ios/library): LibraryDetailViewModel — load + follow-playback + seek"
```

---

### Task 10: LibraryDetailView (portrait split / landscape overlay)

**Files:** Create `whatsub-mobile/Library/LibraryDetailView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct LibraryDetailView: View {
    let entryId: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = LibraryDetailViewModel()
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            if vm.loading {
                ProgressView().tint(.whatsubAccent)
            } else if let err = vm.errorMessage {
                Text(err).foregroundStyle(.whatsubInkMuted).padding()
            } else if let entry = vm.entry {
                if vSize == .compact {
                    landscape(entry)   // landscape phones: compact height
                } else {
                    portrait(entry)
                }
            }
        }
        .navigationTitle(vm.entry?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let token = appState.session?.sessionToken else { return }
            await vm.load(id: entryId, token: token)
        }
        .overlay { if vm.showPopup { highlightPopup } }
    }

    private func player(_ entry: LibraryEntryDetail) -> some View {
        YouTubeEmbedView(videoId: entry.youtubeId, seek: vm.seek) { sec in
            vm.onPlayerTime(sec)
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)
    }

    private func portrait(_ entry: LibraryEntryDetail) -> some View {
        VStack(spacing: 0) {
            player(entry)
            subtitleList(entry)
        }
    }

    private func landscape(_ entry: LibraryEntryDetail) -> some View {
        // Landscape: player fills, subtitles overlaid bottom in a translucent panel.
        ZStack(alignment: .bottom) {
            player(entry)
            subtitleList(entry)
                .frame(maxHeight: 180)
                .background(.black.opacity(0.55))
        }
    }

    private func subtitleList(_ entry: LibraryEntryDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entry.analysisJson.subtitles) { cue in
                        CueRow(
                            cue: cue,
                            isCurrent: cue.index == vm.currentIndex,
                            onTapCue: { vm.seekTo(cue) },
                            onTapHighlight: { w, n, t in vm.showHighlight(word: w, note: n, translation: t) }
                        )
                        .id(cue.index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .onChange(of: vm.currentIndex) { idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    private var highlightPopup: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { vm.showPopup = false }
            VStack(alignment: .leading, spacing: 10) {
                Text(vm.popupWord ?? "").font(.title3.weight(.semibold)).foregroundStyle(.whatsubHighlight)
                if let t = vm.popupTranslation, !t.isEmpty {
                    Text(t).font(.body).foregroundStyle(.whatsubInk)
                }
                if let n = vm.popupNote, !n.isEmpty {
                    Text(n).font(.callout).foregroundStyle(.whatsubInkSoft)
                }
                Button("关闭") { vm.showPopup = false }
                    .font(.footnote).foregroundStyle(.whatsubAccent).padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: 320, alignment: .leading)
            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 16))
            .padding(40)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Library/LibraryDetailView.swift
git commit -m "feat(ios/library): LibraryDetailView — player + follow-scroll + portrait/landscape + highlight popup"
```

---

### Task 11: Push branch + CI (build + tests + screenshot)

**Files:** none (CI)

- [ ] **Step 1: Add an Info.plist ATS note check**

YouTube embeds load from `youtube.com` / `youtube-nocookie.com` / `googlevideo.com` over HTTPS — no ATS exception needed (all HTTPS). No Info.plist change required. (If CI/runtime shows ATS blocks, add `NSAllowsArbitraryLoadsInWebContent: true` — but try without first.)

- [ ] **Step 2: Push the branch**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git push -u origin feat/ios-phase2c-library
```

- [ ] **Step 3: Watch CI**

```bash
gh run watch $(gh run list --repo rjxznb/whatsub-mobile --branch feat/ios-phase2c-library --limit 1 --json databaseId -q '.[0].databaseId') --repo rjxznb/whatsub-mobile --exit-status
```

Expected: build green + unit tests pass (Highlighting + AnalysisDecode + the Phase 2a tests). Iterate on compile errors. Likely watch-outs:
- `onChange(of:)` single-param form (iOS 16) — used in LibraryDetailView; keep single-param.
- `Text` concatenation with modifiers per-run: `Text(...).foregroundColor(...).underline()` then `+` — verify it compiles (Text + Text is supported; modifiers returning Text are `.foregroundColor`/`.underline`/`.fontWeight` which DO return Text. `.font` on the concatenated result is fine).
- `AsyncImage` is iOS 15+ — fine.

- [ ] **Step 4: Fix any failures, re-push until green.**

---

### Task 12: Merge + TestFlight (PAUSE before this — get user authorization)

**Files:** none

**STOP. Get explicit user authorization before merging to main (triggers TestFlight).**

- [ ] **Step 1: Merge + push**

```bash
git checkout main
git merge --no-ff feat/ios-phase2c-library -m "feat(ios): Phase 2c — Library list + bilingual subtitle reader"
git push origin main
git branch -d feat/ios-phase2c-library
git push origin --delete feat/ios-phase2c-library
```

- [ ] **Step 2: Watch testflight.yml → new build**

- [ ] **Step 3: User installs + tests (manual):**
  1. Library tab → pull-to-refresh → synced videos appear
  2. Tap a video → YouTube plays, subtitles below
  3. Subtitles auto-scroll + highlight current line as video plays
  4. Tap a subtitle line → player seeks there
  5. Long-press a line with a yellow highlight → popup shows the phrase meaning
  6. Rotate to landscape → subtitles overlay under the player

---

## Done criteria

- Library tab lists cloud-synced entries with pull-to-refresh + empty/error states
- Tapping an entry opens detail with embedded YouTube + bilingual subtitles
- Subtitles follow playback (auto-scroll + current-cue highlight); tap-to-seek works
- AI-highlighted phrases render yellow; long-press shows meaning popup
- Portrait split / landscape overlay layouts both work
- Unit tests green (Highlighting + AnalysisDecode); CI build green; TestFlight build installs + works end-to-end

Ready for **Phase 2b** (corpus browse + phrase detail) — the last consumer feature.
