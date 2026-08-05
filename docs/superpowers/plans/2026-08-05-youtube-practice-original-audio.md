# YouTube Practice Original Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make “听原文” work in 跟读 and 听抄 for Library entries that only have a YouTube source, without pretending an empty `AVPlayer` can play remote YouTube media.

**Architecture:** Keep `CueAudioPlayer` as the OSS/native AVPlayer path. Add a visible, policy-compliant YouTube cue player built on the existing IFrame API bridge and route each practice sheet through an explicit source enum. YouTube commands seek, apply an actually supported playback rate, play, and auto-pause at the cue end; native commands preserve the current sidecar/shared-player behavior.

**Tech Stack:** Swift 5.10, SwiftUI, WKWebView, YouTube IFrame Player API, AVFoundation, XCTest; no new dependency.

## Global Constraints

- A YouTube practice player is always visible while it can emit YouTube audio; minimum rendered viewport is 200 × 200 points.
- Do not obscure the player with controls or overlays and do not start it before its visible sheet is presented.
- Accept only an 11-character validated YouTube ID before creating the web player.
- YouTube playback rates come from `getAvailablePlaybackRates()`; never send unsupported custom values such as 0.65 or 0.8.
- “听原文” must seek to the current cue, play, and pause at `endTime`, including after Cloze “下一句”.
- The existing OSS audio-sidecar/shared AVPlayer path must not regress.
- Closing a sheet stops the active native or YouTube player, restores the parent native player's saved time/configuration exactly once, and leaves the parent paused for an explicit user resume.
- Every behavior is introduced test-first.

## File Structure

- Create `whatsub-mobile/Practice/OriginalCuePlayback.swift`: source routing and deterministic command/state models.
- Create `whatsub-mobile/Practice/YouTubeCuePlayerView.swift`: visible IFrame cue player surface.
- Modify `whatsub-mobile/Components/YouTubeEmbedView.swift`: reusable command bridge, ready/time/state/error/rate callbacks, and safe teardown.
- Modify `whatsub-mobile/Practice/ShadowSheet.swift`: explicit original-audio source and YouTube-specific visible surface/rates.
- Modify `whatsub-mobile/Practice/ClozeSheet.swift`: same source routing and cue-advance updates.
- Modify `whatsub-mobile/Library/LibraryDetailView.swift`: pass a validated YouTube fallback only when OSS media is absent.
- Create `whatsub-mobileTests/OriginalCuePlaybackTests.swift`.
- Create `whatsub-mobileTests/YouTubePlaybackBridgeTests.swift`.
- Create `whatsub-mobileTests/PracticePlaybackRoutingTests.swift`.

---

### Task 1: Model Explicit Native and YouTube Practice Sources

**Files:**
- Create: `whatsub-mobile/Practice/OriginalCuePlayback.swift`
- Create: `whatsub-mobileTests/OriginalCuePlaybackTests.swift`

**Interfaces:**
- Produces `OriginalCueSource.native(audioURL:videoURL:)`, `.youtube(videoId:)`, and `.unavailable`.
- Exposes a read-only `kind` (`native`, `youtube`, `unavailable`) for presentation/tests without discarding associated values.
- Produces `YouTubePlaybackCommand` with `.seekAndPlay(start:end:rate:nonce:)` and `.pause(nonce:)`.
- Produces pure `OriginalCueSource.resolve(audioURL:videoURL:youtubeId:)`; OSS wins over YouTube, malformed YouTube IDs become unavailable.

- [ ] **Step 1: Write failing routing and command tests**

```swift
func testNativeMediaWinsOverYouTubeFallback() {
    let source = OriginalCueSource.resolve(
        audioURL: URL(string: "https://cdn.example/audio.m4a"),
        videoURL: nil,
        youtubeId: "abcdefghijk"
    )
    XCTAssertEqual(source.kind, .native)
}

func testMalformedYouTubeIdIsUnavailable() {
    XCTAssertEqual(
        OriginalCueSource.resolve(audioURL: nil, videoURL: nil, youtubeId: "bad'</script>"),
        .unavailable
    )
}
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodegen generate
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  test -only-testing:whatsub-mobileTests/OriginalCuePlaybackTests
```

Expected: FAIL because the source and command types do not exist.

- [ ] **Step 3: Implement the minimal pure models**

Do not place `AVPlayer` or `WKWebView` inside the value model. Keep associated
URLs and the validated video ID so views can construct the correct concrete
player without optional combinations.

- [ ] **Step 4: Verify and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  test -only-testing:whatsub-mobileTests/OriginalCuePlaybackTests
git add whatsub-mobile/Practice/OriginalCuePlayback.swift whatsub-mobileTests/OriginalCuePlaybackTests.swift
git commit -m "refactor: model practice audio sources"
```

### Task 2: Extend the YouTube IFrame Bridge with Testable Commands

**Files:**
- Modify: `whatsub-mobile/Components/YouTubeEmbedView.swift`
- Create: `whatsub-mobileTests/YouTubePlaybackBridgeTests.swift`

**Interfaces:**
- `YouTubeEmbedView` accepts an optional `YouTubePlaybackCommand` in addition to the existing Library seek request.
- Adds callbacks `onState`, `onError`, and `onAvailableRates` with no-op defaults so existing call sites remain source-compatible.
- Produces a pure `YouTubeJavaScript.command(_:, supportedRates:)` helper used by `updateUIView` and unit tests.
- Produces a pure `YouTubeCuePlaybackStateMachine` that emits one pause when reported time reaches the command's cue end; the coordinator only applies its effects.

- [ ] **Step 1: Write failing command-sanitization tests**

```swift
func testSeekCommandClampsTimesAndUsesSupportedRate() {
    let command = YouTubePlaybackCommand.seekAndPlay(
        start: 12.25, end: 14.75, rate: 0.65, nonce: UUID()
    )
    let js = try! XCTUnwrap(YouTubeJavaScript.command(command, supportedRates: [0.5, 0.75, 1.0]))
    XCTAssertTrue(js.contains("seekTo(12.25"))
    XCTAssertTrue(js.contains("setPlaybackRate(0.75)"))
    XCTAssertFalse(js.contains("0.65"))
}

func testInvalidTimeNeverProducesExecutableJavaScript() {
    let command = YouTubePlaybackCommand.seekAndPlay(
        start: .nan, end: .infinity, rate: 1, nonce: UUID()
    )
    XCTAssertNil(YouTubeJavaScript.command(command, supportedRates: [1]))
}
```

- [ ] **Step 2: Verify RED**

Run `YouTubePlaybackBridgeTests` with the simulator command from Task 1.

- [ ] **Step 3: Add the bridge without changing current Library behavior**

In HTML, emit `ready`, `time`, `state`, `error`, and `rates`; clear the 250 ms
timer in `dismantleUIView`; expose `pauseVideo`, `seekTo`, and
`setPlaybackRate` only through numeric values generated from validated Swift
models. Preserve the current `SeekRequest` behavior for the Library detail
player.

- [ ] **Step 4: Add cue-end auto-pause tests**

Drive `YouTubeCuePlaybackStateMachine` with synthetic time values and assert
that one pause command is emitted when `time >= endTime`, not repeatedly on
later ticks.

- [ ] **Step 5: Verify and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  test -only-testing:whatsub-mobileTests/YouTubePlaybackBridgeTests
git add whatsub-mobile/Components/YouTubeEmbedView.swift whatsub-mobileTests/YouTubePlaybackBridgeTests.swift
git commit -m "feat: control youtube cue playback"
```

### Task 3: Build a Visible Policy-Compliant YouTube Cue Player

**Files:**
- Create: `whatsub-mobile/Practice/YouTubeCuePlayerView.swift`
- Create: `whatsub-mobileTests/PracticePlaybackRoutingTests.swift`

**Interfaces:**
- `YouTubeCuePlayerView(videoId:cue:command:onReady:onState:onError:onAvailableRates:)` owns no hidden audio surface.
- The embedded viewport is `frame(minWidth: 200, maxWidth: .infinity, minHeight: 200)` and remains visible whenever playback is available.
- Before ready it shows status text outside, not over, the IFrame viewport; player errors become a visible VPN/availability message.

- [ ] **Step 1: Write a failing structural test**

Extract a small testable `YouTubeCuePlayerLayout.minimumViewportSide == 200` and
assert the view rejects an invalid video ID before creating the embed.

- [ ] **Step 2: Verify RED, implement the player surface, verify GREEN**

Keep play controls in the sheet outside this component. Do not use opacity,
zero-size frames, off-screen positioning, or an overlay to hide the official
player while its audio plays.

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Practice/YouTubeCuePlayerView.swift whatsub-mobileTests/PracticePlaybackRoutingTests.swift
git commit -m "feat: add visible youtube practice player"
```

### Task 4: Route Shadowing Playback Through the Correct Player

**Files:**
- Modify: `whatsub-mobile/Practice/ShadowSheet.swift`
- Modify: `whatsub-mobileTests/PracticePlaybackRoutingTests.swift`

**Interfaces:**
- Replace optional URL assumptions with `originalSource: OriginalCueSource` while retaining the native `CueAudioPlayer` instance for `.native`.
- `.youtube` renders `YouTubeCuePlayerView` in a fixed top region outside the scrolling exercise content and drives it with `YouTubePlaybackCommand`.
- Speed chips use the intersection of preferred rates and YouTube-reported rates; native playback retains `[0.5, 0.65, 0.8, 1.0]`.
- “听原文” is enabled for either native or YouTube and reflects loading/playing/error states.

- [ ] **Step 1: Add failing shadow routing tests**

Test native, YouTube, and unavailable presentation models; test that a YouTube
rate unavailable from the IFrame is not shown and the stored 0.65 preference
falls back to the nearest supported rate.

- [ ] **Step 2: Verify RED**

Run `PracticePlaybackRoutingTests` on the simulator.

- [ ] **Step 3: Implement the route and lifecycle**

Remove `guard videoURL != nil` from `playOriginal()`. Native calls
`CueAudioPlayer.play`; YouTube publishes `.seekAndPlay`. Starting countdown or
recording pauses either source. `stopAll()` pauses both and remains idempotent.
Only auto-play after the visible sheet has appeared and the IFrame is ready.

- [ ] **Step 4: Verify and commit**

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  test -only-testing:whatsub-mobileTests/PracticePlaybackRoutingTests
git add whatsub-mobile/Practice/ShadowSheet.swift whatsub-mobileTests/PracticePlaybackRoutingTests.swift
git commit -m "fix: play youtube audio in shadowing"
```

### Task 5: Route Cloze Playback and Cue Advancement

**Files:**
- Modify: `whatsub-mobile/Practice/ClozeSheet.swift`
- Modify: `whatsub-mobileTests/PracticePlaybackRoutingTests.swift`

**Interfaces:**
- `.youtube` renders the same fixed visible player outside the scrolling puzzle content and drives current-cue commands.
- Replay, pause, automatic first play, and “下一句” all use the mutable `currentCue`.
- Advancing cancels the prior cue command before rebuilding the puzzle and playing the new cue.

- [ ] **Step 1: Add failing Cloze command-sequence tests**

```swift
func testAdvancePausesOldCueThenPlaysNewCue() {
    let model = makeClozePlaybackModel(cues: [cue0, cue1], source: .youtube(videoId: "abcdefghijk"))
    model.advance()
    XCTAssertEqual(model.commandKinds, [.pause, .seekAndPlay])
    XCTAssertEqual(model.currentCue.index, cue1.index)
}
```

- [ ] **Step 2: Verify RED, implement routing, verify GREEN**

The button must no longer use `.disabled(videoURL == nil)`; disable only for
`.unavailable` or an explicit player error. Preserve all puzzle generation and
native pre-buffering behavior.

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Practice/ClozeSheet.swift whatsub-mobileTests/PracticePlaybackRoutingTests.swift
git commit -m "fix: play youtube audio in cloze practice"
```

### Task 6: Pass the YouTube Fallback from Library Detail

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Modify: `whatsub-mobileTests/PracticePlaybackRoutingTests.swift`

**Interfaces:**
- Build `OriginalCueSource` once from `ossAudioURL`, `ossVideoURL`, and `entry.youtubeId`.
- Pass the same source into `ShadowSheet` and `ClozeSheet`.
- YouTube is selected only when both OSS URLs are absent and the ID validates.
- Opening either practice sheet pauses the parent native AVPlayer or sends `.pause` to the parent Library YouTube IFrame; dismissing never auto-resumes either one.
- `LibraryDetailView` owns a `YouTubePlaybackCommand?` passed to its existing `YouTubeEmbedView`; setting `shadowCue` or `clozeCue` first issues a fresh pause command, then presents the sheet.

- [ ] **Step 1: Add the failing Library routing regression**

Cover four fixtures: audio sidecar, OSS video only, YouTube only, and a
non-YouTube desktop-only source. Assert their source kinds are native, native,
YouTube, and unavailable respectively. Also assert both practice presentation
actions pause the parent command target before changing the sheet item.

- [ ] **Step 2: Verify RED, wire both sheets, verify GREEN**

Keep the main Library YouTube embed behavior unchanged; the sheet gets a
separate visible embed because WKWebView instances cannot be re-parented safely
between the detail screen and a presented sheet.

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Library/LibraryDetailView.swift whatsub-mobileTests/PracticePlaybackRoutingTests.swift
git commit -m "fix: route youtube-only practice audio"
```

### Task 7: Full Verification and Device Checks

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-05-mobile-background-analysis-and-youtube-practice-design.md` only if implementation uncovered a factual mismatch.

- [ ] **Step 1: Run the complete iOS build and test suite**

```bash
xcodegen generate
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  build CODE_SIGNING_REQUIRED=NO
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test
```

Expected: build and all tests pass.

- [ ] **Step 2: Test on a physical iPhone with VPN enabled**

For a YouTube-only Library entry, verify visible playback in both sheets,
replay, pause, cue-end stop, Shadow speed choices, recording handoff, Cloze
auto-play, “下一句”, close cleanup, and a clear unavailable message when VPN is
off. Repeat one OSS entry to prove the native path still uses its sidecar.

- [ ] **Step 3: Check YouTube presentation requirements**

On the smallest supported iPhone simulator/device, measure at least 200 × 200
points for the visible IFrame, verify no control overlays cover it, and verify
audio cannot continue after hiding or dismissing the player.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md
# Add the design spec only if implementation required a factual correction.
git commit -m "docs: record youtube practice playback"
```
