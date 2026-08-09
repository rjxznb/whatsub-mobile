# iOS Cue Layout, Stop Popover, and YouTube Shadow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve subtitle word order with natural rich-text wrapping, anchor the managed-analysis stop confirmation to its button, and enable Shadow original-audio playback for YouTube-only Library entries.

**Architecture:** A pure `CueTextPresentation` helper converts stored cue text and highlight runs into normalized ordered display runs; `CueRow` turns those runs into one linked `AttributedString`. A button-scoped `ManagedAnalysisStopButton` owns its confirmation presentation. A shared `YouTubeClipPlaybackController` publishes safe nonce-bearing iframe commands used by both the existing `YouTubeEmbedView` and `ShadowSheet`.

**Tech Stack:** Swift 5.10, SwiftUI, WebKit `WKWebView`, YouTube IFrame Player API, XCTest, XcodeGen, GitHub Actions macOS CI.

## Global Constraints

- Deployment target remains iOS 16.0 and no third-party Swift dependency may be added.
- Persisted cue text, SRT, cue boundaries, timestamps, translations, backend payloads, and fullscreen caption rendering must not change.
- Subtitle English remains 22 pt, left aligned; highlights remain yellow, semibold, underlined, and tappable for the existing gloss callback.
- Ordinary cue taps still seek; long press still exposes collect, Shadow, Cloze, and copy actions.
- Stop confirmation copy and cancellation behavior remain unchanged; only the presentation owner moves to the Stop button.
- YouTube Shadow playback must reuse the existing detail-page iframe; do not create a second hidden player or extract direct media URLs.
- OSS Shadow playback keeps `0.5×`, `0.65×`, `0.8×`, `1.0×`; YouTube uses `0.5×`, `0.75×`, `1.0×`.
- The Windows host has neither Swift nor Xcode. Red/green compiler evidence must come from the existing macOS GitHub Actions CI workflow.

---

### Task 1: Ordered rich-text cue presentation

**Files:**
- Create: `whatsub-mobile/Library/CueTextPresentation.swift`
- Modify: `whatsub-mobile/Library/CueRow.swift`
- Create: `whatsub-mobileTests/CueTextPresentationTests.swift`

**Interfaces:**
- Consumes: `splitForHighlights(_:highlights:) -> [HighlightRun]` from `Library/Highlighting.swift` and the existing `CueRow.onTapHighlight` callback.
- Produces: `CueTextPresentation.make(text:highlights:) -> CueTextPresentation`, ordered `CueDisplayRun` values with `text`, `highlightID`, and original `phrase`, plus `plainText`; `CueRow` renders one `AttributedString` and resolves `whatsub-highlight://<id>` back to a run.

- [ ] **Step 1: Write failing ordering and punctuation tests**

Create `CueTextPresentationTests.swift` with tests equivalent to:

```swift
func testNewlinesCannotReorderProductionCue() {
    let value = CueTextPresentation.make(
        text: "-They love you.\nWe love you. Welcome back.",
        highlights: ["Welcome back"]
    )
    XCTAssertEqual(value.plainText, "-They love you. We love you. Welcome back.")
    XCTAssertEqual(value.runs.map(\.text).joined(), value.plainText)
    XCTAssertEqual(value.highlightPhrase(id: 0), "Welcome back")
    XCTAssertFalse(value.plainText.contains("back ."))
}

func testSecondProductionCueKeepsImBeforeExcited() {
    let value = CueTextPresentation.make(
        text: "Congrats. July 4th.\nI'm excited about the premiere.",
        highlights: ["premiere"]
    )
    XCTAssertEqual(value.plainText, "Congrats. July 4th. I'm excited about the premiere.")
}

func testWhitespaceAcrossRunBoundariesCollapsesOnce() {
    let value = CueTextPresentation.make(text: "Use  catch up \n now!", highlights: ["catch up"])
    XCTAssertEqual(value.plainText, "Use catch up now!")
    XCTAssertEqual(value.highlightPhrase(id: 0), "catch up")
}
```

- [ ] **Step 2: Push the test-only commit and verify CI is red**

Run:

```bash
git add whatsub-mobileTests/CueTextPresentationTests.swift
git commit -m "test: reproduce cue word reordering"
git push -u origin codex/fix-cue-layout-popover
gh run watch --exit-status
```

Expected: CI fails because `CueTextPresentation` is not defined.

- [ ] **Step 3: Implement ordered display runs**

Create the helper with value types:

```swift
struct CueDisplayRun: Equatable {
    let text: String
    let highlightID: Int?
    let phrase: String?
}

struct CueTextPresentation: Equatable {
    let runs: [CueDisplayRun]
    var plainText: String { runs.map(\.text).joined() }
    func highlightPhrase(id: Int) -> String? {
        runs.first { $0.highlightID == id }?.phrase
    }
    static func make(text: String, highlights: [String]) -> Self {
        var result: [CueDisplayRun] = []
        var nextHighlightID = 0
        var pendingSpace: (id: Int?, phrase: String?)?

        func append(_ text: String, id: Int?, phrase: String?) {
            guard !text.isEmpty else { return }
            if let last = result.last,
               last.highlightID == id,
               last.phrase == phrase {
                result[result.count - 1] = CueDisplayRun(
                    text: last.text + text, highlightID: id, phrase: phrase
                )
            } else {
                result.append(CueDisplayRun(text: text, highlightID: id, phrase: phrase))
            }
        }

        for source in splitForHighlights(text, highlights: highlights) {
            let id = source.highlight ? nextHighlightID : nil
            let phrase = source.highlight ? source.text : nil
            if source.highlight { nextHighlightID += 1 }
            for character in source.text {
                if character.isWhitespace {
                    pendingSpace = (id, phrase)
                    continue
                }
                if let pendingSpace, !result.isEmpty {
                    let sameStyle = pendingSpace.id == id && pendingSpace.phrase == phrase
                    append(" ", id: sameStyle ? id : nil, phrase: sameStyle ? phrase : nil)
                }
                pendingSpace = nil
                append(String(character), id: id, phrase: phrase)
            }
        }
        return CueTextPresentation(runs: result)
    }
}
```

`make` must iterate `splitForHighlights`, collapse every contiguous `Character.isWhitespace` sequence to one space, keep internal highlight spaces under the same numeric ID, avoid leading/trailing spaces, and coalesce adjacent runs with identical highlight metadata.

- [ ] **Step 4: Replace `CueRow` word chips with one attributed paragraph**

Remove `WordToken`, `tokens`, and the English `FlowLayout`. Build one `AttributedString` from `CueTextPresentation.runs`; assign a private link `whatsub-highlight://<id>`, yellow foreground, semibold 22 pt font, and underline to highlighted runs. Render it with one `Text`, `.font(.system(size: 22))`, `.multilineTextAlignment(.leading)`, and a scoped `OpenURLAction` that invokes the existing callback with `cue.highlightTranslations[phrase]` and `cue.keyNotes[phrase]`. Unknown links return `.discarded`; normal card taps retain `onTapCue`.

- [ ] **Step 5: Run focused and existing highlighting tests through CI**

Commit and push:

```bash
git add whatsub-mobile/Library/CueTextPresentation.swift whatsub-mobile/Library/CueRow.swift whatsub-mobileTests/CueTextPresentationTests.swift
git commit -m "fix: preserve subtitle word order in cue cards"
git push
gh run watch --exit-status
```

Expected: simulator build and all XCTest cases pass.

---

### Task 2: Button-anchored stop confirmation

**Files:**
- Create: `whatsub-mobile/Library/ManagedAnalysisStopButton.swift`
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Create: `whatsub-mobileTests/ManagedAnalysisStopButtonSourceTests.swift`

**Interfaces:**
- Consumes: `isBusy: Bool` and `onConfirm: () -> Void`.
- Produces: `ManagedAnalysisStopButton`, whose root button owns local `@State isConfirming` and its `.confirmationDialog`.

- [ ] **Step 1: Write and push a failing source-ownership regression test**

Use `#filePath` to resolve the checked-out repository and assert that the root
detail view does not own the stop-specific state/copy while the button component
does. Other confirmation dialogs in the detail view are unrelated and remain:

```swift
func testStopConfirmationIsOwnedByStopButtonInsteadOfDetailRoot() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = tests.deletingLastPathComponent()
    let detail = try String(contentsOf: root.appendingPathComponent(
        "whatsub-mobile/Library/LibraryDetailView.swift"), encoding: .utf8)
    let buttonURL = root.appendingPathComponent(
        "whatsub-mobile/Library/ManagedAnalysisStopButton.swift")
    XCTAssertTrue(FileManager.default.fileExists(atPath: buttonURL.path))
    let button = try String(contentsOf: buttonURL, encoding: .utf8)
    XCTAssertFalse(detail.contains("confirmStopAnalysis"))
    XCTAssertFalse(detail.contains("停止 AI 解析？"))
    XCTAssertTrue(button.contains(".confirmationDialog("))
    XCTAssertTrue(button.contains("停止 AI 解析？"))
    XCTAssertTrue(button.contains("停止解析"))
    XCTAssertTrue(button.contains("已完成的翻译会保留"))
}
```

Commit and push only this test, then run `gh run watch --exit-status`.
Expected: RED because the component file does not exist.

- [ ] **Step 2: Extract the stop button and presentation owner**

Create:

```swift
struct ManagedAnalysisStopButton: View {
    let isBusy: Bool
    let onConfirm: () -> Void
    @State private var isConfirming = false
    var body: some View {
        Button(isBusy ? "正在停止…" : "停止") { isConfirming = true }
            .confirmationDialog("停止 AI 解析？", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("停止解析", role: .destructive, action: onConfirm)
                Button("继续解析", role: .cancel) {}
            } message: {
                Text("已完成的翻译会保留，未完成部分将停止解析，之后可以继续。")
            }
    }
}
```

Move the existing font, borderless style, red foreground, and disabled condition onto this component at the banner call site. Delete root `confirmStopAnalysis` state and root `.confirmationDialog`. `onConfirm` obtains the session token and calls `vm.cancelManagedAnalysis(token:)` exactly as before.

- [ ] **Step 3: Verify source ownership and compile in CI**

Run local structural checks before the macOS build:

```bash
rg -n "confirmStopAnalysis|confirmationDialog" whatsub-mobile/Library/LibraryDetailView.swift whatsub-mobile/Library/ManagedAnalysisStopButton.swift
git diff --check
```

Expected: no `confirmStopAnalysis` or stop-dialog title in the detail view; the
stop confirmation appears in `ManagedAnalysisStopButton.swift`. Unrelated edit
and desktop-replacement dialogs remain in the detail view.

Commit and push:

```bash
git add whatsub-mobile/Library/ManagedAnalysisStopButton.swift whatsub-mobile/Library/LibraryDetailView.swift whatsub-mobileTests/ManagedAnalysisStopButtonSourceTests.swift
git commit -m "fix: anchor stop confirmation to analysis button"
git push
gh run watch --exit-status
```

Expected: CI build and tests pass.

---

### Task 3: Safe shared YouTube clip commands

**Files:**
- Create: `whatsub-mobile/Components/YouTubeClipPlaybackController.swift`
- Modify: `whatsub-mobile/Components/YouTubeEmbedView.swift`
- Create: `whatsub-mobileTests/YouTubeClipPlaybackControllerTests.swift`

**Interfaces:**
- Produces: `YouTubeClipPlaybackCommand: Equatable` with `kind`, optional `start/end/rate`, and `nonce`; `@MainActor final class YouTubeClipPlaybackController: ObservableObject` with `play(start:end:rate:) -> Bool`, `setRate(_:)`, `stop()`, `clipEnded()`, and published `command` plus `isPlaying`; `YouTubeEmbedView.clipCommand` consumes it and `onClipEnded` reports iframe completion.
- Downstream Task 4 consumes the controller from `LibraryDetailView` and `ShadowSheet`.

- [ ] **Step 1: Write failing command validation tests**

Cover:

```swift
@MainActor
func testRepeatedPlayCreatesDistinctCommands() {
    let controller = YouTubeClipPlaybackController()
    XCTAssertTrue(controller.play(start: 10, end: 12, rate: 1))
    let first = controller.command
    XCTAssertTrue(controller.play(start: 10, end: 12, rate: 1))
    XCTAssertNotEqual(first?.nonce, controller.command?.nonce)
}

@MainActor
func testPlayRejectsInvalidRangeAndNumbers() {
    let controller = YouTubeClipPlaybackController()
    XCTAssertFalse(controller.play(start: 2, end: 2, rate: 1))
    XCTAssertFalse(controller.play(start: .nan, end: 3, rate: 1))
    XCTAssertFalse(controller.play(start: 1, end: .infinity, rate: 1))
    XCTAssertNil(controller.command)
}

@MainActor
func testPlayClampsNegativeStartAndRate() {
    let controller = YouTubeClipPlaybackController()
    XCTAssertTrue(controller.play(start: -2, end: 3, rate: 9))
    XCTAssertEqual(controller.command?.start, 0)
    XCTAssertEqual(controller.command?.rate, 2)
}

@MainActor
func testStopAndRateCommandsUseFreshNonces() {
    let controller = YouTubeClipPlaybackController()
    XCTAssertTrue(controller.play(start: 1, end: 2, rate: 1))
    controller.setRate(0.5)
    let rateNonce = controller.command?.nonce
    controller.stop()
    XCTAssertNotEqual(rateNonce, controller.command?.nonce)
    XCTAssertFalse(controller.isPlaying)
}

func testClipJavaScriptContainsBoundaryAndPauseLogic() {
    let play = YouTubeClipPlaybackCommand.play(start: 1, end: 2, rate: 0.75)
    let script = YouTubeEmbedView.clipJavaScript(for: play) ?? ""
    XCTAssertTrue(script.contains("seekTo(1.0"))
    XCTAssertTrue(script.contains("whatsubClipEnd = 2.0"))
    XCTAssertTrue(script.contains("getAvailablePlaybackRates"))
    XCTAssertTrue(script.contains("playVideo"))
    let stop = YouTubeEmbedView.clipJavaScript(for: .stop()) ?? ""
    XCTAssertTrue(stop.contains("pauseVideo"))
}
```

Assert repeated equal plays have different nonces; `end <= start`, NaN, and infinity return false without publishing; negative start becomes zero; rate is clamped to `0.25...2.0`; JavaScript never interpolates non-finite values and includes `seekTo`, `setPlaybackRate`, `playVideo`, clip-end assignment, and `pauseVideo` for stop.

- [ ] **Step 2: Push test-only commit and verify CI is red**

```bash
git add whatsub-mobileTests/YouTubeClipPlaybackControllerTests.swift
git commit -m "test: specify youtube cue clip controls"
git push
gh run watch --exit-status
```

Expected: CI fails because the controller and clip JavaScript interface are absent.

- [ ] **Step 3: Implement the controller and iframe command bridge**

The controller validates and publishes commands only on the main actor. Extend `YouTubeEmbedView` with optional `clipCommand`, coordinator `lastClipCommand`, and internal static `clipJavaScript(for:) -> String?` used by tests. In `updateUIView`, evaluate a new clip command independently from normal `SeekRequest` processing.

Extend iframe HTML with `window.whatsubClipEnd = null`. In the existing 250 ms interval, if current time reaches the boundary, call `pauseVideo()`, clear it, and post `{type:'clipEnded'}` before posting the ordinary time update. Play commands choose the closest value from `player.getAvailablePlaybackRates()` to the requested safe rate, set it, seek, and play. Stop clears the boundary and pauses. Rate commands change only the active player rate. The coordinator forwards `clipEnded` to its closure, and `LibraryDetailView` calls `controller.clipEnded()`.

- [ ] **Step 4: Commit, push, and verify CI green**

```bash
git add whatsub-mobile/Components/YouTubeClipPlaybackController.swift whatsub-mobile/Components/YouTubeEmbedView.swift whatsub-mobileTests/YouTubeClipPlaybackControllerTests.swift
git commit -m "feat: add shared youtube cue clip controls"
git push
gh run watch --exit-status
```

Expected: simulator build and all tests pass.

---

### Task 4: Route Shadow original audio through the existing iframe

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Modify: `whatsub-mobile/Practice/ShadowSheet.swift`
- Create: `whatsub-mobileTests/ShadowPlaybackAvailabilityTests.swift`

**Interfaces:**
- Consumes: `YouTubeClipPlaybackController` and its command API from Task 3.
- Produces: pure `ShadowPlaybackSource` selection (`oss` / `youtube` / `unavailable`) used consistently by button availability, speed presets, play, rate, and stop paths.

- [ ] **Step 1: Write failing source-selection tests**

Define expected behavior in `ShadowPlaybackAvailabilityTests.swift`:

```swift
XCTAssertEqual(ShadowPlaybackSource.resolve(hasOSS: true, hasYouTube: true), .oss)
XCTAssertEqual(ShadowPlaybackSource.resolve(hasOSS: false, hasYouTube: true), .youtube)
XCTAssertEqual(ShadowPlaybackSource.resolve(hasOSS: false, hasYouTube: false), .unavailable)
XCTAssertEqual(ShadowPlaybackSource.youtube.availableRates, [0.5, 0.75, 1.0])
XCTAssertEqual(ShadowPlaybackSource.oss.availableRates, [0.5, 0.65, 0.8, 1.0])
```

- [ ] **Step 2: Push test-only commit and verify CI red**

```bash
git add whatsub-mobileTests/ShadowPlaybackAvailabilityTests.swift
git commit -m "test: require youtube original audio in shadow practice"
git push
gh run watch --exit-status
```

Expected: CI fails because `ShadowPlaybackSource` is absent.

- [ ] **Step 3: Integrate source selection and lifecycle**

Add `ShadowPlaybackSource` beside `ShadowSheet`. Extend the initializer with a nonoptional shared `YouTubeClipPlaybackController` and `youtubePlaybackAvailable: Bool`. Resolve OSS first, then YouTube. Replace every `videoURL == nil` disabled/guard check with source availability. Route:

- OSS play/stop/rate to existing `CueAudioPlayer`.
- YouTube play to `controller.play(start: cue.time, end: cue.endTime, rate:)`.
- YouTube stop and dismiss/record/retry cleanup to `controller.stop()`.
- YouTube live speed changes to `controller.setRate(_:)`.

Use source-specific speed presets; on appear, reset an unsupported persisted rate to `1.0`. Observe `controller.isPlaying` for button labeling; the iframe `clipEnded` bridge is authoritative for returning it to idle after buffered playback actually reaches the cue end.

In `LibraryDetailView`, own one `@StateObject YouTubeClipPlaybackController`, pass `clipCommand` into the existing YouTube player, and pass the same controller plus `VideoSource.isLikelyYouTubeId(entry.youtubeId) && entry.videoUrl == nil` into `ShadowSheet`. Opening Shadow pauses the iframe through `stop()`.

- [ ] **Step 4: Verify all call sites and CI**

Run structural checks:

```bash
rg -n "ShadowSheet\(" whatsub-mobile
rg -n "disabled\(videoURL == nil\)|guard videoURL != nil" whatsub-mobile/Practice/ShadowSheet.swift
git diff --check
```

Expected: every initializer supplies the new controller contract; Shadow contains no OSS-only availability gate.

Commit and push:

```bash
git add whatsub-mobile/Library/LibraryDetailView.swift whatsub-mobile/Practice/ShadowSheet.swift whatsub-mobileTests/ShadowPlaybackAvailabilityTests.swift
git commit -m "fix: play youtube originals in shadow practice"
git push
gh run watch --exit-status
```

Expected: full CI build, unit tests, simulator launch, and screenshot artifact succeed.

---

### Task 5: Whole-branch verification

**Files:**
- Review only: all files changed since `main`.

**Interfaces:**
- Consumes: completed Tasks 1-4.
- Produces: verified merge-ready branch with no deployment or TestFlight action.

- [ ] **Step 1: Inspect the complete branch diff and requirements**

```bash
git diff --check main...HEAD
git diff --stat main...HEAD
git log --oneline main..HEAD
rg -n "FlowLayout" whatsub-mobile/Library/CueRow.swift
rg -n "confirmStopAnalysis" whatsub-mobile/Library/LibraryDetailView.swift
rg -n "disabled\(videoURL == nil\)|guard videoURL != nil" whatsub-mobile/Practice/ShadowSheet.swift
```

Expected: no whitespace errors; no CueRow word flow; no root stop state; no OSS-only Shadow gate.

- [ ] **Step 2: Verify latest GitHub Actions run from the final HEAD**

```bash
git push
gh run list --branch codex/fix-cue-layout-popover --limit 1
gh run watch --exit-status
```

Expected: the run corresponding to final `HEAD` succeeds for simulator build, complete XCTest suite, app install/launch, and screenshot upload.

- [ ] **Step 3: Record release boundary**

Confirm no backend repository files changed and no TestFlight workflow was triggered. Deployment and TestFlight require a separate explicit user request after device validation.
