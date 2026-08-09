# iOS Cue Layout and Stop Popover Design

## Background

Library subtitle cards currently render every whitespace-separated English word
as a separate SwiftUI view inside `FlowLayout`. YouTube captions commonly retain
author-authored line breaks. A token such as `you.\nWe` therefore becomes one
two-line view while later words continue to occupy the first visual row. The
stored sentence remains correct, but the screen appears to reorder it. A
production example is stored as:

```text
-They love you.\nWe love you. Welcome back.
```

and is incorrectly displayed as if `We` appeared after `Welcome`.

The same word-chip layout also inserts fixed spacing between a highlighted phrase
and adjacent punctuation, producing text such as `back .`.

The managed-analysis stop confirmation is attached to the root detail view. On
popover-style presentations, SwiftUI therefore chooses a root-level anchor high
in the player area instead of the red Stop button in the analysis banner.

## Goals

1. Display every English cue in its original character order.
2. Collapse source whitespace, including line breaks, into normal inter-word
   spaces in Library cards and let the system wrap the sentence naturally.
3. Preserve the current 22-point typography, yellow underlined highlights, and
   tap-to-open highlight gloss interaction.
4. Preserve card-level tap-to-seek and long-press practice actions.
5. Anchor the stop-analysis confirmation directly to the Stop button.
6. Enable `听原文` in Shadow practice for YouTube-only Library entries by
   reusing the detail page's existing IFrame player.
7. Leave persisted cues, SRT, timestamps, translations, backend data, and the
   fullscreen video-caption renderer unchanged.

## Non-goals

- Do not rewrite or resync existing Library entries.
- Do not attempt to correct genuine transcription mistakes.
- Do not change cue boundaries or merge adjacent cues.
- Do not change the managed-analysis cancellation API or state machine.
- Do not redesign subtitle card dimensions, colors, or font sizes.
- Do not extract unstable direct YouTube media URLs or create a second hidden
  YouTube player inside the practice sheet.

## Chosen design

### Natural rich-text cue rendering

Replace the per-word `FlowLayout` in `CueRow` with one SwiftUI `Text` backed by an
`AttributedString`. A small pure presentation helper will:

1. Reuse `splitForHighlights` so highlight matching stays identical to the video
   overlay and existing Library behavior.
2. Stream the resulting runs in source order.
3. Collapse every contiguous whitespace sequence to one ordinary space, including
   whitespace that crosses a highlight boundary.
4. Preserve punctuation exactly next to the preceding or following text; no
   synthetic word spacing is inserted.
5. Assign each highlight run a deterministic local link identifier while retaining
   the original phrase as the key for `highlightTranslations` and `keyNotes`.

`CueRow` will render the complete attributed value as one left-aligned paragraph.
SwiftUI's text engine owns wrapping, so a source newline can no longer create a
two-line child that visually overtakes neighboring words. Highlight links use a
private URL scheme intercepted by a scoped `OpenURLAction`; tapping one invokes
the existing `onTapHighlight` callback and never leaves the app. Tapping ordinary
text or card space continues to seek the cue.

The helper exposes normalized plain text and ordered runs independently of the
view. XCTest can therefore verify ordering and punctuation without snapshot-test
infrastructure.

### Button-anchored stop confirmation

Move the stop confirmation state and `.confirmationDialog` modifier into a small
view whose root is the red Stop button. It receives cancelling/resuming state and
an `onConfirm` callback. Because the presentation modifier belongs to the button,
popover-capable devices and window sizes use the button as their source anchor.
Compact iPhone presentations remain the system-standard action sheet.

The confirmation copy and cancellation call remain unchanged:

- Title: `停止 AI 解析？`
- Message: completed translations remain; unfinished work stops and can resume.
- Destructive action: call `cancelManagedAnalysis` with the current session token.

### YouTube-backed Shadow original audio

`ShadowSheet` currently treats `videoURL == nil` as "no original audio". That
property only represents an OSS URL, so every YouTube-only entry disables the
button even though `LibraryDetailView` already owns a ready IFrame player.

Add one `YouTubeClipPlaybackController` owned by `LibraryDetailView`. It publishes
a nonce-bearing command value consumed by the existing `YouTubeEmbedView`:

- `play(start:end:rate:)` seeks to the cue start, selects the closest playback
  rate supported by the IFrame API, starts playback, and records the cue end.
- `setRate(_:)` changes the active clip rate without seeking.
- `stop()` clears the active clip boundary and pauses the IFrame player.

The IFrame's existing 250 ms timer will also compare `getCurrentTime()` with the
active clip end. It pauses and clears the boundary when the end is reached. This
is more reliable than a wall-clock timeout because buffering does not consume cue
playback time.

`ShadowSheet` receives the shared controller plus an explicit
`youtubePlaybackAvailable` flag. Its original-audio availability becomes:

```text
OSS audio/video available OR YouTube IFrame available
```

The sheet continues to use `CueAudioPlayer` for OSS entries. For YouTube-only
entries, play/pause/rate actions go through the shared controller. Opening the
sheet pauses the underlying IFrame, and dismissing, recording, retrying, or
closing stops any active YouTube clip. The underlying video is not automatically
resumed, matching the existing OSS practice behavior.

YouTube's supported practice presets are `0.5×`, `0.75×`, and `1.0×`. OSS keeps
its existing `0.5×`, `0.65×`, `0.8×`, and `1.0×` presets. If the persisted choice
is unavailable for the current source, the sheet selects `1.0×` rather than
showing a speed that the player will ignore.

## Error handling and interaction details

- Invalid or unrecognized private highlight links return `.discarded` and do not
  invoke a gloss callback.
- Highlight phrases containing punctuation, spaces, Unicode, or URL-sensitive
  characters are addressed by numeric run identifiers, avoiding lossy encoding.
- If no highlights exist, the same rich-text path renders a normal sentence.
- Empty/whitespace-only display text remains harmless; cue storage is untouched.
- While cancellation or resume is active, the Stop button remains disabled as it
  is today.
- YouTube clip commands reject non-finite times, clamp starts to zero, ensure the
  end is later than the start, and clamp rates to a safe positive range before
  generating JavaScript.
- A YouTube-only item with an invalid/non-YouTube ID remains unavailable; the
  iframe is never created and Shadow does not claim original audio support.

## Verification

Add regression tests proving that the normalized display text for the production
examples is exactly:

```text
-They love you. We love you. Welcome back.
Congrats. July 4th. I'm excited about the premiere.
```

Tests also prove that a highlighted `Welcome back` remains one tappable highlight,
the following period has no inserted space, and multiple whitespace characters
collapse without changing word order. Controller tests prove that repeated clip
plays emit distinct commands, invalid ranges are rejected, and stop/rate commands
remain scoped to the existing iframe. Existing highlighting, Shadow, and
managed-analysis tests must continue to pass. The macOS CI simulator build is the
authoritative compiler verification because the development machine is
Windows-only.
