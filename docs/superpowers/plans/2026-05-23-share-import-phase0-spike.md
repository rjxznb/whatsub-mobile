# Share-to-Import Phase 0 Spike (YouTube caption capture on iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** Validate (go/no-go) that an iOS WKWebView playing a YouTube video, with the plugin's `fetchHook.js` injected, can intercept the player's `/api/timedtext` request and that the ported `parseTimedtextJson3` turns it into subtitle cues. Throwaway spike behind a temp debug entry.

**Architecture:** A `WKWebView` loads a YouTube watch page (CC force-on via `cc_load_policy=1`). A MAIN-world (`.page`) user script (adapted `fetchHook.js`) hooks `fetch`/XHR; when the player fetches `/api/timedtext` it posts the body to a `WKScriptMessageHandler`. Swift parses it with `parseTimedtextJson3` and the spike screen shows the captured cue count + first cues. **Cannot be validated in CI** (no VPN / no YouTube reachability in the CI simulator) — validated by the user on TestFlight with a VPN.

**Tech Stack:** SwiftUI + WebKit (WKWebView, WKUserScript `.page` world, WKScriptMessageHandler) · XCTest.

**Spec:** `docs/superpowers/specs/2026-05-23-share-to-import-design.md`.
**Port references** (`C:\Users\renjx\Desktop\whatsub-plugin`): `web-plugin/public/fetchHook.js`, `web-plugin/src/sw/transcripts/parseTimedtextJson3.ts`, `web-plugin/src/cs/youtube/injectFetchHook.ts`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `whatsub-mobile/Import/TimedtextParser.swift` | Port of `parseTimedtextJson3` — json3 → `[SpikeCue]` | Create |
| `whatsub-mobile/Import/CaptionHookJS.swift` | The adapted `fetchHook.js` as a Swift string constant (posts to `webkit.messageHandlers`) | Create |
| `whatsub-mobile/Import/CaptionSpikeView.swift` | WKWebView + hook injection + capture + results UI | Create |
| `whatsub-mobileTests/TimedtextParserTests.swift` | json3 fixture → cues | Create |
| `whatsub-mobile/Views/MeView.swift` (or wherever the 我的 tab lives) | temp NavigationLink "🧪 字幕提取 spike" | Modify |

All `Import/` files + the temp entry are throwaway — Phase 1 reuses `TimedtextParser` + `CaptionHookJS` but replaces the spike UI.

---

## Pre-flight
```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git checkout main && git pull && git checkout -b spike/yt-caption-capture
```

---

### Task 1: Port parseTimedtextJson3 (TDD)

**Files:** Create `whatsub-mobile/Import/TimedtextParser.swift` + `whatsub-mobileTests/TimedtextParserTests.swift`

- [ ] **Step 1: Failing test.** `whatsub-mobileTests/TimedtextParserTests.swift`:
```swift
import XCTest
@testable import whatsub_mobile

final class TimedtextParserTests: XCTestCase {
    func testParsesJson3Events() throws {
        let json = #"""
        {"events":[
          {"tStartMs":0,"dDurationMs":1500,"segs":[{"utf8":"Hello "},{"utf8":"there."}]},
          {"tStartMs":1500,"dDurationMs":2000,"segs":[{"utf8":"How are you?"}]},
          {"tStartMs":3500,"dDurationMs":1000,"segs":[{"utf8":"   "}]}
        ]}
        """#.data(using: .utf8)!
        let cues = parseTimedtextJson3(json)
        XCTAssertEqual(cues.count, 2) // blank-only event dropped
        XCTAssertEqual(cues[0].idx, 0)
        XCTAssertEqual(cues[0].text, "Hello there.")
        XCTAssertEqual(cues[0].time, 0.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 1.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "How are you?")
        XCTAssertEqual(cues[1].time, 1.5, accuracy: 0.001)
    }

    func testEmptyOrBadInput() {
        XCTAssertEqual(parseTimedtextJson3(Data("{}".utf8)).count, 0)
        XCTAssertEqual(parseTimedtextJson3(Data("not json".utf8)).count, 0)
    }
}
```

- [ ] **Step 2: Run → RED** (deferred to CI; locally just confirm the symbol is referenced).

- [ ] **Step 3: Implement `TimedtextParser.swift`** (direct port of `parseTimedtextJson3.ts`):
```swift
import Foundation

/// One subtitle cue parsed from a YouTube timedtext json3 response.
/// Mirror of the plugin's `Cue` (web-plugin/src/sw/transcripts/parseTimedtextJson3.ts).
struct SpikeCue: Equatable {
    let idx: Int
    let time: Double   // seconds
    let end: Double    // seconds
    let text: String
}

/// Parse a YouTube `/api/timedtext?...&fmt=json3` body into cues.
/// json3 shape: { events: [ { tStartMs, dDurationMs, segs: [{ utf8 }] } ] }.
/// Blank/whitespace-only events are dropped (matches the plugin).
func parseTimedtextJson3(_ data: Data) -> [SpikeCue] {
    guard
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let events = root["events"] as? [[String: Any]]
    else { return [] }

    var cues: [SpikeCue] = []
    var idx = 0
    for e in events {
        guard let segs = e["segs"] as? [[String: Any]] else { continue }
        let text = segs.map { ($0["utf8"] as? String) ?? "" }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let startMs = (e["tStartMs"] as? NSNumber)?.doubleValue ?? 0
        let durMs = (e["dDurationMs"] as? NSNumber)?.doubleValue ?? 0
        let start = startMs / 1000.0
        cues.append(SpikeCue(idx: idx, time: start, end: start + durMs / 1000.0, text: text))
        idx += 1
    }
    return cues
}
```

- [ ] **Step 4: Commit:**
```bash
git add whatsub-mobile/Import/TimedtextParser.swift whatsub-mobileTests/TimedtextParserTests.swift
git commit -m "spike(import): port parseTimedtextJson3 to Swift + TDD"
```

---

### Task 2: Caption hook JS (adapted for WKWebView)

**Files:** Create `whatsub-mobile/Import/CaptionHookJS.swift`

- [ ] **Step 1:** Adapt the plugin's `fetchHook.js` — same fetch/XHR hook, but `post()` sends straight to the WKWebView message handler (`window.webkit.messageHandlers.whatsubCaptions`) instead of `window.postMessage` (no Chrome two-world relay needed). Store as a Swift string:
```swift
import Foundation

/// MAIN-world (`.page`) script: hooks window.fetch + XMLHttpRequest so that when
/// the YouTube player fetches /api/timedtext (its own po_token-signed request),
/// we capture the body and hand it to Swift via the `whatsubCaptions` message
/// handler. Adapted from the whatsub-plugin web-plugin/public/fetchHook.js
/// (post() retargeted to webkit.messageHandlers). Must be injected at
/// documentStart so it installs before the player's first timedtext request.
enum CaptionHookJS {
    static let source = #"""
    (function installCaptionsHook() {
      if (window.__whatsubHookInstalled) return;
      window.__whatsubHookInstalled = true;
      function isTimedtext(u){ return typeof u === "string" && u.indexOf("/api/timedtext") !== -1; }
      function post(url, body){
        try { window.webkit.messageHandlers.whatsubCaptions.postMessage({ url: url, body: body }); } catch(e){}
      }
      var origFetch = window.fetch;
      window.fetch = function(input, init){
        var p = origFetch.apply(this, arguments);
        try {
          var url = typeof input === "string" ? input : (input && input.url) ? input.url : String(input);
          if (isTimedtext(url)) {
            p.then(function(res){
              if (!res || !res.ok) return;
              res.clone().text().then(function(t){ if (t) post(url, t); }).catch(function(){});
            }).catch(function(){});
          }
        } catch(e){}
        return p;
      };
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, url){ try { this.__wsUrl = String(url); } catch(e){} return origOpen.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(){
        var url = this.__wsUrl, xhr = this;
        if (url && isTimedtext(url)) {
          this.addEventListener("load", function(){ try { if (xhr.status===200 && xhr.responseText) post(url, xhr.responseText); } catch(e){} });
        }
        return origSend.apply(this, arguments);
      };
    })();
    """#
}
```

- [ ] **Step 2: Commit:**
```bash
git add whatsub-mobile/Import/CaptionHookJS.swift
git commit -m "spike(import): caption fetch hook JS (WKWebView-adapted)"
```

---

### Task 3: CaptionSpikeView (WKWebView + capture + results)

**Files:** Create `whatsub-mobile/Import/CaptionSpikeView.swift`

- [ ] **Step 1: Implement.** A WKWebView that loads the YouTube watch page with CC forced on, the hook injected at documentStart in `.page` world, a `whatsubCaptions` handler (also `.page` world) that parses captured bodies, and a results panel.
```swift
import SwiftUI
import WebKit

struct CaptionSpikeView: View {
    // A known captioned video; the user can edit it in the field.
    @State private var videoId = "ECXAFUmdJkI"
    @State private var status = "待加载"
    @State private var cues: [SpikeCue] = []
    @State private var rawLen = 0
    @State private var reload = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("YouTube videoId", text: $videoId)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("加载") { cues = []; rawLen = 0; status = "加载中…"; reload = UUID() }
            }
            Text("状态：\(status)").font(.footnote).foregroundStyle(.whatsubInkMuted)
            Text("捕获 cue：\(cues.count)  | 原始字节：\(rawLen)").font(.footnote).foregroundStyle(.whatsubInk)

            CaptionCaptureWebView(videoId: videoId, reload: reload) { body in
                rawLen = body.utf8.count
                let parsed = parseTimedtextJson3(Data(body.utf8))
                cues = parsed
                status = parsed.isEmpty ? "捕获到 timedtext 但解析为空（可能非 json3，见原始字节）" : "成功捕获 + 解析 ✅"
            }
            .frame(height: 200)
            .background(Color.black)

            List(cues.prefix(8), id: \.idx) { c in
                VStack(alignment: .leading) {
                    Text(String(format: "%.1f–%.1f", c.time, c.end)).font(.caption2).foregroundStyle(.whatsubInkFaint)
                    Text(c.text).font(.footnote).foregroundStyle(.whatsubInk)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding()
        .background(Color.whatsubBg.ignoresSafeArea())
        .navigationTitle("字幕提取 spike")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Loads the YouTube watch page with CC forced on, injects the caption hook in
/// the page (MAIN) world at documentStart, and forwards captured timedtext
/// bodies to `onCaptions`.
private struct CaptionCaptureWebView: UIViewRepresentable {
    let videoId: String
    let reload: UUID
    let onCaptions: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCaptions: onCaptions) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let hook = WKUserScript(source: CaptionHookJS.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        cfg.userContentController.addUserScript(hook)
        cfg.userContentController.add(context.coordinator, contentWorld: .page, name: "whatsubCaptions")
        let web = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.load(web, videoId: videoId)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastReload != reload {
            context.coordinator.lastReload = reload
            context.coordinator.load(web, videoId: videoId)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onCaptions: (String) -> Void
        var lastReload: UUID?
        init(onCaptions: @escaping (String) -> Void) { self.onCaptions = onCaptions }

        func load(_ web: WKWebView, videoId: String) {
            // Watch page with CC force-on (cc_load_policy=1) + auto-select an
            // English track. The full player fetches /api/timedtext when CC loads;
            // the hook (installed at documentStart) catches it.
            let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)&cc_load_policy=1")!
            web.load(URLRequest(url: url))
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "whatsubCaptions",
                  let dict = message.body as? [String: Any],
                  let body = dict["body"] as? String else { return }
            DispatchQueue.main.async { self.onCaptions(body) }
        }
    }
}
```
(NOTE: if the watch page redirects to `m.youtube.com` or shows a consent wall in WKWebView, that's a spike finding — try the embed instead: load `YouTubeEmbedView`'s HTML with `cc_load_policy: 1` in playerVars + autoplay muted, same hook. The implementer can add a toggle if the watch page misbehaves, but ship the watch-page version first.)

- [ ] **Step 2: Commit:**
```bash
git add whatsub-mobile/Import/CaptionSpikeView.swift
git commit -m "spike(import): WKWebView caption capture + results screen"
```

---

### Task 4: Temp entry in the 我的 tab

**Files:** Modify the 我的-tab view (find it: `grep -rl '我的\|MeView' whatsub-mobile/`)

- [ ] **Step 1:** Add a temporary `NavigationLink` to `CaptionSpikeView()` in the 我的 tab's list (clearly marked throwaway). If MeView isn't in a NavigationStack, wrap the link target appropriately or add a `.sheet`. Minimal example row:
```swift
NavigationLink("🧪 字幕提取 spike") { CaptionSpikeView() }
```
- [ ] **Step 2: Commit:**
```bash
git add -A whatsub-mobile/
git commit -m "spike(import): temp entry in 我的 tab"
```

---

### Task 5: Push + CI (build only)

- [ ] **Step 1:** Push `spike/yt-caption-capture`; watch CI. Expected: build green + TimedtextParserTests pass. (CI canNOT validate the capture — no VPN/YouTube.) Watch-outs: `WKUserScript(...in: .page)` + `userContentController.add(_:contentWorld:name:)` are iOS 14+ (fine on iOS 16). Fix compile errors, re-push until green.

---

### Task 6: TestFlight + user validation — PAUSE for user

**STOP. Get authorization to merge to main + TestFlight (cert slots).** This spike must reach a device because only a real device with a VPN can reach YouTube.

- [ ] **Step 1:** Merge to main + TestFlight (standard).
- [ ] **Step 2:** User (VPN ON) installs → 我的 → 🧪 字幕提取 spike → loads the default video → reports:
  - 捕获 cue count > 0 + sample cues look like real subtitles → **GO** (the whole approach is validated; proceed to Phase 1 plan).
  - "捕获到 timedtext 但解析为空" → the body isn't json3 (note the format; adjust the parser or force `&fmt=json3`).
  - 0 cues / status stuck → the watch page didn't fetch timedtext in WKWebView → try the embed variant (Task 3 note), or the player needs an explicit CC-track selection.

---

## Done criteria (spike)
- `parseTimedtextJson3` ported + unit-tested (CI green).
- On a real device with VPN: loading a captioned YouTube video in the spike screen captures the player's `/api/timedtext` and shows parsed cues.
- A clear GO / NO-GO + the specific finding (which load mode worked, json3 vs other) recorded — feeds the Phase 1 plan.

## Notes
- Throwaway: `Import/CaptionSpikeView.swift` + the temp entry get removed in Phase 1; `TimedtextParser.swift` + `CaptionHookJS.swift` are kept + reused.
- This is the riskiest unknown in the whole share-to-import feature; validating it cheaply here prevents building Phase 1 on a broken foundation.
