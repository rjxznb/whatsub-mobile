# Library Player Retry and Resume Design

## Goal

Make both Library playback paths recoverable and resumable without leaving the detail page:

- VPN-dependent YouTube playback through `YouTubeEmbedView` / WKWebView;
- VPN-free OSS playback through native `AVPlayer`.

When a player fails or times out, the user can reload it in place. When the user leaves a video and returns later, playback seeks to the last persisted position but remains paused. Progress resets only after the player explicitly reports that playback reached the end.

## Scope

This is an iOS-only, local feature. It adds no backend endpoint, database write, account synchronization, entitlement gate, analytics payload, or autoplay behavior. Progress survives app restarts and upgrades but is removed with the app.

## Persistent progress

Add a bounded local `PlaybackProgressStore` using an atomically written JSON file under Application Support. Records are keyed by Library `entryId`, so a video keeps its position if its playback source later changes from YouTube to OSS after desktop replacement.

Each record contains the latest finite, non-negative playback second and an update timestamp. Values are normalized to whole-second precision. The store ignores invalid values and recovers from a missing or corrupt file as an empty store. A bounded least-recently-used policy prevents indefinite growth; 500 entries is sufficient because the Pro Library limit is lower than that.

The existing player callbacks report time about four times per second. `LibraryDetailView` retains the latest in-memory value but persists at most once every five seconds. It also flushes the latest value when the detail view disappears and when the app enters the background.

## Resume semantics

On detail load, the view reads the saved position before constructing the playback surface.

- Native AVPlayer seeks after the current item becomes ready.
- YouTube receives the saved offset when constructing the iframe and issues a pause after readiness to guarantee that restoration never autoplays.
- With no saved record, playback starts at zero.
- A saved position near the end is still restored. There is no percentage or remaining-time heuristic.
- Progress is removed only after an explicit completion event:
  - `AVPlayerItemDidPlayToEndTime` for native playback;
  - YouTube IFrame `onStateChange` with `YT.PlayerState.ENDED`.
- Leaving, backgrounding, buffering, failing, or timing out never counts as completion.

After an explicit completion event, the current player generation enters a completed state so trailing end-of-stream time callbacks cannot immediately recreate the deleted record. If the user subsequently replays or seeks back from the end, a new playing/seek signal exits that state and later partial progress is persisted normally.

The restore action is idempotent per player generation. Later subtitle seeks and collection timestamp seeks continue to work and take precedence over the initial restore.

## In-place reload

The existing loading overlay becomes an actionable error surface for both playback paths. After the 15-second timeout it displays a primary `重新加载` button while retaining the VPN-specific hint for YouTube and a network hint for OSS.

`LibraryDetailView` owns a monotonically changing reload generation. Tapping reload:

1. captures and persists the latest known position;
2. resets `playerReady` and `playerTimedOut`;
3. invalidates the previous timeout generation;
4. rebuilds the active playback surface;
5. restores the captured position while paused after readiness.

For YouTube, changing the generation changes the representable identity and constructs a fresh WKWebView/iframe instead of relying on `WKWebView.reload()`. This recovers iframe/API bootstrap failures more reliably.

For OSS, reload replaces the current `AVPlayerItem` or player with a fresh item created from the current signed video URL. It reattaches readiness, time, caption, end-of-playback, and background-audio observation through the existing `VideoPlayerView` lifecycle.

Before rebuilding OSS playback, an explicit reload performs the existing Library detail refresh once so an expired signed URL can be replaced. This reuses the current read endpoint and adds no API. If the refresh fails but the existing URL remains available, the player may still retry that URL; the overlay remains visible if readiness is not reached.

`YouTubeEmbedView` forwards IFrame `onError` in addition to relying on the timeout for failures that occur before the IFrame API boots. `VideoPlayerView` forwards AVPlayer item/status failure. Either explicit failure displays the same actionable overlay immediately; a bootstrap or network hang falls back to the 15-second timeout.

Each 15-second timeout task captures its generation and may update the UI only if that generation is still current. A delayed timeout from an old failed player therefore cannot cover a newly ready player.

## Component boundaries

- `PlaybackProgressStore`: local validation, atomic persistence, bounded LRU, read/save/clear operations.
- `PlayerReloadState`: pure generation and timeout-validity decisions for deterministic tests.
- `YouTubeEmbedView`: forwards ready/time/ended signals and restores a supplied start position without autoplay.
- `VideoPlayerView`: forwards ready/time/ended signals for AVPlayer.
- `LibraryDetailView`: coordinates source selection, reload generation, saved-position restoration, throttled persistence, lifecycle flush, and overlay actions.

No component directly calls the backend for playback progress.

## Error handling

- Progress persistence failures never block playback or show a modal error.
- Corrupt progress JSON is discarded safely.
- Invalid or non-finite player times are ignored.
- A reload can be attempted repeatedly; every attempt receives a new generation and timeout.
- A signed OSS URL is refreshed only through the existing detail endpoint and only after the user explicitly retries; this feature introduces no progress or reload endpoint.

## Testing

Tests must cover:

- round-trip persistence, corrupt-file recovery, invalid-time rejection, and 500-entry LRU eviction;
- five-second write throttling plus explicit lifecycle flush;
- restore while paused for both YouTube and AVPlayer;
- no record starts at zero;
- near-end progress remains stored;
- only explicit YouTube/AVPlayer completion clears progress;
- repeated reloads increment generation and stale timeout generations are ignored;
- YouTube reload creates a new playback surface and does not reuse the failed iframe;
- AVPlayer reload creates a fresh item/player and retains the latest position;
- existing cue seek, clip playback, captions, fullscreen, background audio, and player-source selection tests remain green.

## Release order

This feature has no backend dependency. After implementation, full iOS CI must pass at the exact final commit, including unit tests, simulator build/install, screenshot, and artifact upload. TestFlight is triggered only after review approval and integration into `main`.
