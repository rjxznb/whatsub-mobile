# Library Player Retry and Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-place reload and local resume-position persistence to both VPN-dependent YouTube playback and VPN-free native AVPlayer playback in Library detail.

**Architecture:** A file-backed actor stores bounded per-entry progress, while pure session/reload state types own throttling, completion suppression, and stale-timeout decisions. Existing YouTube and AVPlayer wrappers emit matching ready/time/failure/ended events; `LibraryDetailView` coordinates restoration, explicit reload, lifecycle flush, and the shared error overlay without adding a backend contract.

**Tech Stack:** Swift 5.10, SwiftUI, WebKit WKWebView, AVKit/AVFoundation, XCTest, XcodeGen, GitHub Actions macOS CI.

## Global Constraints

- Support both Library sources: YouTube iframe playback requiring VPN and OSS/CDN playback using native AVPlayer without VPN.
- Restore the last position while paused; never autoplay as part of restoration or reload.
- Preserve positions even one second from the end. Clear only after an explicit YouTube `ENDED` or `AVPlayerItemDidPlayToEndTime` event.
- Replaying or seeking back after completion starts a new resumable session; trailing end callbacks must not recreate the cleared record.
- Persist locally only. Add no backend endpoint, database write, account sync, entitlement gate, or analytics payload.
- Store at most 500 records, use atomic JSON writes under Application Support, ignore invalid times, and recover from corrupt JSON.
- Persist no more than once every five seconds during playback, then force-flush on detail disappearance and app backgrounding.
- A reload attempt preserves the latest position, remains paused after restoration, and receives a new generation so stale 15-second timeouts cannot affect it.
- YouTube reload creates a fresh WKWebView/iframe. AVPlayer reload refreshes Library detail through the existing read endpoint and constructs a fresh player/item from the latest available signed URL.
- Keep existing cue seeks, bounded clip playback, captions, fullscreen, roleplay pause, and background-audio behavior working.
- Do not merge, deploy, or trigger TestFlight until the final task passes independent review.

---

### Task 1: Add the bounded progress store and pure playback session state

**Files:**
- Create: `whatsub-mobile/Library/PlaybackProgressStore.swift`
- Create: `whatsub-mobile/Library/PlaybackResumeSession.swift`
- Create: `whatsub-mobileTests/PlaybackProgressStoreTests.swift`
- Create: `whatsub-mobileTests/PlaybackResumeSessionTests.swift`

**Interfaces:**
- Produces: `actor PlaybackProgressStore`
- Produces: `func position(for entryID: String) -> Double?`
- Produces: `func save(position: Double, for entryID: String, now: Date = Date())`
- Produces: `func clear(entryID: String)`
- Produces: `struct PlaybackResumeSession` with `beginReload()`, `markReady(generation:)`, `receiveTime(_:now:)`, `markEnded()`, `shouldAcceptTimeout(generation:)`, and `forceFlushDecision(now:)`
- Produces: `enum PlaybackPersistenceDecision { case none, save(Double), clear }`

- [ ] **Step 1: Write failing store tests**

Add tests using an injected temporary `fileURL`:

```swift
func testRoundTripNormalizesToWholeSeconds() async {
    let store = PlaybackProgressStore(fileURL: fileURL, capacity: 500)
    await store.save(position: 42.8, for: "entry-1", now: Date(timeIntervalSince1970: 10))
    let reloaded = PlaybackProgressStore(fileURL: fileURL, capacity: 500)
    XCTAssertEqual(await reloaded.position(for: "entry-1"), 42)
}

func testInvalidTimesAreIgnoredAndCorruptFileRecovers() async throws {
    try Data("not-json".utf8).write(to: fileURL)
    let store = PlaybackProgressStore(fileURL: fileURL, capacity: 500)
    await store.save(position: .nan, for: "bad")
    await store.save(position: -1, for: "negative")
    XCTAssertNil(await store.position(for: "bad"))
    XCTAssertNil(await store.position(for: "negative"))
    await store.save(position: 7, for: "good")
    XCTAssertEqual(await store.position(for: "good"), 7)
}

func testEvictsLeastRecentlyUsedPastFiveHundred() async {
    let store = PlaybackProgressStore(fileURL: fileURL, capacity: 500)
    for index in 0..<500 {
        await store.save(position: Double(index + 1), for: "e-\(index)", now: Date(timeIntervalSince1970: Double(index)))
    }
    _ = await store.position(for: "e-0")
    await store.save(position: 501, for: "e-500", now: Date(timeIntervalSince1970: 501))
    XCTAssertNotNil(await store.position(for: "e-0"))
    XCTAssertNil(await store.position(for: "e-1"))
}
```

- [ ] **Step 2: Write failing session-state tests**

```swift
func testPersistsAtMostEveryFiveSecondsAndForceFlushes() {
    var session = PlaybackResumeSession(restoredPosition: 20)
    XCTAssertEqual(session.receiveTime(21, now: date(0)), .save(21))
    XCTAssertEqual(session.receiveTime(22, now: date(4.9)), .none)
    XCTAssertEqual(session.receiveTime(26, now: date(5)), .save(26))
    XCTAssertEqual(session.receiveTime(27, now: date(6)), .none)
    XCTAssertEqual(session.forceFlushDecision(now: date(6)), .save(27))
}

func testOnlyExplicitEndClearsAndTrailingTimesStaySuppressed() {
    var session = PlaybackResumeSession(restoredPosition: 99)
    XCTAssertEqual(session.receiveTime(100, now: date(0)), .save(100))
    XCTAssertEqual(session.markEnded(), .clear)
    XCTAssertEqual(session.receiveTime(100, now: date(6)), .none)
    XCTAssertEqual(session.forceFlushDecision(now: date(7)), .none)
    XCTAssertEqual(session.receiveTime(0, now: date(8)), .save(0))
}

func testReloadGenerationRejectsOldTimeout() {
    var session = PlaybackResumeSession(restoredPosition: 12)
    let first = session.beginReload()
    let second = session.beginReload()
    XCTAssertFalse(session.shouldAcceptTimeout(generation: first))
    XCTAssertTrue(session.shouldAcceptTimeout(generation: second))
    session.markReady(generation: second)
    XCTAssertFalse(session.shouldAcceptTimeout(generation: second))
}
```

- [ ] **Step 3: Push RED tests and verify expected CI failure**

```powershell
git add whatsub-mobileTests/PlaybackProgressStoreTests.swift whatsub-mobileTests/PlaybackResumeSessionTests.swift
git commit -m 'test: define playback resume persistence'
git push origin codex/video-learning-guide
gh run list --workflow ci.yml --branch codex/video-learning-guide --limit 1
```

Expected: simulator app build can pass, but unit-test compilation fails because the two production types do not exist.

- [ ] **Step 4: Implement the atomic store**

Use a private Codable envelope with a version and dictionary of records. Resolve the default file as:

```swift
FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("whatsub", isDirectory: true)
    .appendingPathComponent("playback_progress.json")
```

Create the parent directory, decode lazily, trim entry IDs, floor valid positions to whole seconds, update LRU access on reads, and persist that access update so ordering survives relaunch. Evict the oldest `lastAccessedAt`, then write with `Data.write(options: .atomic)`. Swallow persistence errors so playback never fails because of local storage.

- [ ] **Step 5: Implement the pure session state**

`receiveTime` rejects non-finite/negative values, saves immediately on the first accepted time, then every `>= 5` seconds. `markEnded` enters completion suppression and returns `.clear`. While completed, same-tail callbacks return `.none`; a later time at least one second below the completed tail exits suppression and can save. `beginReload` increments an integer generation, resets readiness, and returns the generation. Only the current not-ready generation accepts timeout.

- [ ] **Step 6: Commit GREEN implementation after full CI**

```powershell
git add whatsub-mobile/Library/PlaybackProgressStore.swift whatsub-mobile/Library/PlaybackResumeSession.swift
git commit -m 'feat: persist local playback positions'
git push origin codex/video-learning-guide
```

Expected: full `ci.yml` succeeds, including all tests, simulator build/install, screenshot, and artifact.

### Task 2: Add symmetric YouTube lifecycle events and paused restoration

**Files:**
- Modify: `whatsub-mobile/Components/YouTubeEmbedView.swift`
- Modify: `whatsub-mobileTests/YouTubeClipPlaybackControllerTests.swift`
- Create: `whatsub-mobileTests/YouTubeEmbedLifecycleTests.swift`

**Interfaces:**
- Changes: `YouTubeEmbedView` adds `resumeSeconds: Double?`, `onFailure: () -> Void`, and `onEnded: () -> Void`
- Produces: `YouTubeBridgeEvent.decode(_:)` as a pure decoder from a script-message dictionary
- Produces: bridge message types `ready`, `time`, `clipEnded`, `failure`, and `ended`
- Preserves: existing `startSeconds`, clip commands, replay snapshot, and clip-ended behavior

- [ ] **Step 1: Write failing HTML and bridge tests**

```swift
func testResumeScriptSeeksThenPausesWithoutAutoplay() {
    let html = YouTubeEmbedView.html(videoId: "dQw4w9WgXcQ", startSeconds: nil, resumeSeconds: 42)
    XCTAssertTrue(html.contains("seekTo(42"))
    XCTAssertTrue(html.contains("pauseVideo"))
    XCTAssertFalse(html.contains("autoplay: 1"))
}

func testHTMLForwardsEndedAndPlayerErrors() {
    let html = YouTubeEmbedView.html(videoId: "dQw4w9WgXcQ", startSeconds: nil, resumeSeconds: nil)
    XCTAssertTrue(html.contains("YT.PlayerState.ENDED"))
    XCTAssertTrue(html.contains("type: 'ended'"))
    XCTAssertTrue(html.contains("onError"))
    XCTAssertTrue(html.contains("type: 'failure'"))
}
```

Add pure decoder tests that pass bridge dictionaries into `YouTubeBridgeEvent.decode(_:)` and assert `ready`, `time`, `clipEnded`, `failure`, `ended`, and malformed messages map correctly. Keep existing clip delivery tests unchanged; the coordinator becomes a thin switch over the decoded event.

- [ ] **Step 2: Push RED and verify failure**

```powershell
git add whatsub-mobileTests/YouTubeEmbedLifecycleTests.swift whatsub-mobileTests/YouTubeClipPlaybackControllerTests.swift
git commit -m 'test: define youtube reload lifecycle events'
git push origin codex/video-learning-guide
```

Expected: compilation fails on the new `resumeSeconds` HTML signature and lifecycle callbacks.

- [ ] **Step 3: Implement the bridge without changing existing consumers**

Keep `startSeconds` as the existing corpus/phrase start option. Add a separate finite, non-negative `resumeSeconds`. In `onReady`, when resume exists, execute `seekTo(resume, false)` and `pauseVideo()` before posting `ready`. Add IFrame `onStateChange` and `onError` handlers that post `ended` and `failure`. Map those messages in the coordinator. Do not call `playVideo()` during restore.

- [ ] **Step 4: Commit GREEN after full CI**

```powershell
git add whatsub-mobile/Components/YouTubeEmbedView.swift whatsub-mobileTests/YouTubeEmbedLifecycleTests.swift whatsub-mobileTests/YouTubeClipPlaybackControllerTests.swift
git commit -m 'feat: report youtube reload and completion events'
git push origin codex/video-learning-guide
```

Expected: existing corpus phrase playback and bounded clip tests remain green.

### Task 3: Add native AVPlayer failure, completion, and paused restoration

**Files:**
- Modify: `whatsub-mobile/Components/VideoPlayerView.swift`
- Create: `whatsub-mobileTests/VideoPlayerLifecycleTests.swift`

**Interfaces:**
- Changes: `VideoPlayerView` adds `resumeSeconds: Double?`, `onFailure: () -> Void`, and `onEnded: () -> Void`
- Produces: app-owned `AVPlayerLifecycleEvent` and `AVPlayerLifecycleDecision` pure mapping for ready, failed, and ended events
- Preserves: captions, fullscreen overlay, seek requests, background audio, and time callbacks

- [ ] **Step 1: Write failing lifecycle decision tests**

```swift
func testReadyWithResumeSeeksButDoesNotPlay() {
    XCTAssertEqual(
        AVPlayerLifecycleDecision.ready(resumeSeconds: 42),
        .seekPaused(42)
    )
    XCTAssertEqual(AVPlayerLifecycleDecision.ready(resumeSeconds: nil), .ready)
}

func testFailedAndEndedMapToDistinctCallbacks() {
    XCTAssertEqual(AVPlayerLifecycleDecision.forEvent(.itemFailed), .failure)
    XCTAssertEqual(AVPlayerLifecycleDecision.forEvent(.didPlayToEnd), .ended)
}
```

Add a regression assertion that ordinary `SeekRequest` still maps to seek-and-play, because subtitle/corpus taps are explicit user playback actions and differ from passive restoration.

- [ ] **Step 2: Push RED and verify failure**

```powershell
git add whatsub-mobileTests/VideoPlayerLifecycleTests.swift
git commit -m 'test: define native player resume lifecycle'
git push origin codex/video-learning-guide
```

Expected: unit-test compilation fails because lifecycle decisions and new callbacks do not exist.

- [ ] **Step 3: Implement AVPlayer item observation**

Observe the current item status for `.readyToPlay` and `.failed`, translate framework values into the app-owned lifecycle event, and register `AVPlayerItemDidPlayToEndTime` for that exact item. On first ready, seek to finite non-negative `resumeSeconds` with zero tolerance and leave the player paused; then signal ready. Do not invoke `play()`. Keep explicit `SeekRequest` behavior as seek followed by play. Remove item observation and notification tokens in `detach()`.

- [ ] **Step 4: Commit GREEN after full CI**

```powershell
git add whatsub-mobile/Components/VideoPlayerView.swift whatsub-mobileTests/VideoPlayerLifecycleTests.swift
git commit -m 'feat: report native player reload and completion events'
git push origin codex/video-learning-guide
```

Expected: native player, captions, fullscreen, Now Playing, and background-audio tests/build remain green.

### Task 4: Integrate persistence and in-place reload in Library detail

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Modify: `whatsub-mobile/Library/LibraryDetailViewModel.swift`
- Modify: `whatsub-mobileTests/LibraryDesktopReplacementTests.swift`
- Create: `whatsub-mobileTests/LibraryPlaybackRecoveryTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `PlaybackProgressStore`, `PlaybackResumeSession`, YouTube lifecycle callbacks, and AVPlayer lifecycle callbacks
- Produces: `LibraryPlayerSource` / `LibraryPlayerRecoveryAction` pure decisions used by view tests
- Produces: `LibraryPlayerErrorPresentation` pure source-specific title/detail/reload-button model
- Produces: `LibraryDetailViewModel.refreshPlaybackDetail(id:token:) async throws -> LibraryEntryDetail`, reusing `LibraryDesktopReplacementAPI.libraryEntry`
- Changes: timeout overlay gains a primary `重新加载` button for both YouTube and OSS

- [ ] **Step 1: Write failing recovery-action tests**

```swift
func testYouTubeReloadRebuildsWithoutDetailRefresh() {
    XCTAssertEqual(
        LibraryPlayerRecoveryAction.forSource(.youtube),
        .rebuildYouTube
    )
}

func testOSSReloadRefreshesSignedURLThenRebuildsPlayer() {
    XCTAssertEqual(
        LibraryPlayerRecoveryAction.forSource(.oss),
        .refreshDetailThenRebuildAVPlayer
    )
}

func testReloadPreservesLatestPositionAndStartsNewGeneration() {
    var session = PlaybackResumeSession(restoredPosition: 30)
    _ = session.receiveTime(47, now: date(0))
    let generation = session.beginReload()
    XCTAssertEqual(session.resumePosition, 47)
    XCTAssertEqual(generation, 1)
}
```

Add `LibraryPlayerErrorPresentation` tests asserting the timed-out overlay model exposes `重新加载` for both source kinds, uses the VPN hint only for YouTube, and uses the network hint for OSS. The SwiftUI overlay renders this model rather than being introspected directly.

In `LibraryDesktopReplacementTests`, add an async test proving `refreshPlaybackDetail` performs exactly one `libraryEntry` read, publishes the refreshed signed URL, and does not enter page-level loading or start a managed-analysis request.

- [ ] **Step 2: Push RED and verify failure**

```powershell
git add whatsub-mobileTests/LibraryPlaybackRecoveryTests.swift whatsub-mobileTests/LibraryDesktopReplacementTests.swift
git commit -m 'test: define library player recovery flow'
git push origin codex/video-learning-guide
```

Expected: tests fail because recovery decisions and integration are missing.

- [ ] **Step 3: Load and restore progress before player construction**

After `vm.load`, await `PlaybackProgressStore.shared.position(for: entryId)`, initialize the session, and then create the AVPlayer if the detail has an OSS URL. Pass `session.resumePosition` to either playback wrapper. Both wrappers must remain paused after readiness.

- [ ] **Step 4: Route time, completion, failure, and lifecycle flushes**

Replace direct `vm.onPlayerTime` closures with a helper that first updates subtitles, then applies `session.receiveTime`; execute `.save`/`.clear` asynchronously against the store. On explicit ended, call `markEnded` and clear. On wrapper failure, mark the current generation timed out immediately. On view disappearance and inactive/background scene phases, call `forceFlushDecision` without clearing near-end progress.

- [ ] **Step 5: Implement source-specific reload**

YouTube reload increments generation, resets ready/timeout state, and changes the embed identity with `.id("youtube-\(entry.id)-\(generation)")` so a new WKWebView is built. OSS reload force-flushes, sets `avPlayer = nil`, calls the new lightweight `refreshPlaybackDetail` method once to obtain and publish the latest detail without toggling the page-level loading state or restarting managed-analysis work, then creates a fresh AVPlayer from the refreshed URL or the last available URL. Pass the retained resume position and do not play automatically.

- [ ] **Step 6: Make timeout tasks generation-safe**

Replace the unkeyed player `.task` with `.task(id: session.generation)` (or an equivalent immutable generation token). After 15 seconds, set `playerTimedOut` only when `session.shouldAcceptTimeout(generation:)` returns true. `onReady` marks that exact generation ready.

- [ ] **Step 7: Add the shared reload button and update documentation**

The timed-out overlay contains:

```swift
Button("重新加载") { reloadActivePlayer() }
    .buttonStyle(.borderedProminent)
```

Retain `YouTube 视频需挂 VPN 观看` for YouTube. Replace “重进本页” copy with actionable source-specific text. Document local paused resume, explicit-end clearing, and both-source in-place reload in `README.md`.

- [ ] **Step 8: Commit GREEN and wait for exact-head CI**

```powershell
git add whatsub-mobile/Library/LibraryDetailView.swift whatsub-mobile/Library/LibraryDetailViewModel.swift whatsub-mobileTests/LibraryPlaybackRecoveryTests.swift whatsub-mobileTests/LibraryDesktopReplacementTests.swift README.md
git commit -m 'feat: reload and resume library playback'
git push origin codex/video-learning-guide
```

Run:

```powershell
$head = git rev-parse HEAD
gh run list --workflow ci.yml --branch codex/video-learning-guide --limit 3 --json databaseId,headSha,status,conclusion,url
```

Expected: the successful run's `headSha` equals `$head`; unit tests, simulator build/install, screenshot, and artifact upload all succeed.

### Task 5: Cross-feature review and release handoff

**Files:**
- Modify production or test files only when a concrete review finding is reproduced first

**Interfaces:**
- Consumes: all prior tasks
- Produces: reviewed mobile branch ready for integration

- [ ] **Step 1: Review the complete player diff**

Compare YouTube and AVPlayer event sequences side by side. Check restore never invokes play, completion is the only clear path, post-completion replay can persist again, old timeout generations are ignored, OSS refresh cannot accidentally preserve an obsolete AVPlayer, and YouTube rebuild actually changes representable identity. Check existing clip commands and explicit cue seeks still play.

- [ ] **Step 2: Run fresh exact-head verification**

Confirm `git diff --check`, a clean tracked worktree, branch/remote equality, and a full successful mobile CI at exact HEAD. Search the feature diff for backend changes, secrets, autoplay, percentage completion heuristics, or accidental analytics payloads; none are allowed.

- [ ] **Step 3: Request independent code review**

Package the complete feature diff from the pre-spec base through final HEAD. A fresh read-only reviewer must check persistence safety, lifecycle races, both reload paths, no-autoplay behavior, completion semantics, and regression coverage. Fix every Critical/Important finding with a failing test before production edits, then repeat full CI and fresh review.

- [ ] **Step 4: Present integration options**

After approval, use `superpowers:finishing-a-development-branch` and present merge/PR/keep choices. Only after the user chooses merge should the merged `main` receive a final CI run and TestFlight workflow.
