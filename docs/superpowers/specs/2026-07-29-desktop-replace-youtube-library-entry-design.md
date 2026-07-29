# Desktop replacement for phone-parsed YouTube entries

**Date:** 2026-07-29

## Problem

A YouTube video parsed on iOS has subtitles and analysis in Library, but no self-hosted OSS video. Playback therefore uses the embedded YouTube player and requires VPN access. The user needs an explicit way to send that existing entry to the desktop client, which can download the media, transcribe it again, analyse it, upload it, and replace the phone-produced transcript and analysis.

This is a replacement of an existing Library entry, not a new import and not a product-tier upgrade.

## User experience

Only a Library detail whose source is YouTube and whose `videoUrl` is absent shows the action **“发送到桌面端下载”**.

The explanatory copy states that the computer must have whatSub installed and signed into the same account. The desktop will download the video, regenerate subtitles and analysis, and upload the media; only after every stage succeeds will the existing subtitles be replaced.

The action reuses the existing desktop-presence behavior:

- The task is enqueued first.
- The enqueue response includes `desktopSeenSecondsAgo`.
- A missing heartbeat or a heartbeat older than 120 seconds is treated as offline.
- If online, iOS says processing will start shortly.
- If offline, iOS shows a yellow warning that the task is queued and will begin after the desktop app is opened and signed into the same account.
- Import Queue and the existing Live Activity remain the progress surfaces.

Repeated taps do not create duplicate pending/processing replacement jobs. While one exists, the detail action indicates that the task is waiting for or running on the desktop.

## Queue contract

The existing `import_queue` gains two fields:

- `mode`: `import` (default, preserving current clients) or `replace`
- `target_library_entry_id`: nullable for ordinary imports and required for replacement jobs

iOS sends the canonical YouTube URL, `mode: "replace"`, and the current Library entry ID. The backend validates before enqueueing that:

- the target entry belongs to the authenticated account;
- it is a YouTube entry;
- it does not already have an OSS-hosted video;
- the URL's YouTube ID agrees with the target entry's `youtube_id`/ID;
- no pending or processing replacement job exists for the same owner and target.

A replacement job does not consume an additional Library video slot. Ordinary import quota behavior remains unchanged.

Queue list responses expose the two new fields so the desktop can choose the correct completion rules and iOS can recognize an already-enqueued replacement.

## Desktop processing

The desktop claims replacement jobs through the existing poller and runs the normal media pipeline:

1. Download the YouTube video.
2. Generate a fresh Whisper transcript.
3. Generate fresh LLM analysis from that transcript.
4. Upload the required media objects and cover to OSS.
5. Submit a replacement sync targeting the original Library entry ID.
6. Mark the queue job `done` only after the replacement endpoint succeeds.

For a YouTube entry, the generated video ID is expected to equal the target ID, but the desktop must check this instead of relying on it implicitly. A mismatch fails the job without modifying Library.

## Atomic replacement

The existing phone-produced entry remains readable throughout processing. The desktop must not use the ordinary partial-sync behavior for a replacement job.

The final backend operation validates ownership and job/target identity again, then updates the existing row in one database transaction with:

- fresh transcript SRT;
- fresh analysis JSON;
- desktop-derived metadata;
- OSS video/audio/thumbnail object keys;
- updated sync timestamp/version fingerprint.

The queue row becomes `done` in the same transaction. No Library mutation occurs when download, transcription, analysis, media upload, or final validation fails. Uploaded objects that cannot be attached because the target was deleted or validation failed are cleaned up best-effort.

The Library entry ID is unchanged. Existing corpus phrases and other references anchored by `libraryEntryId` therefore remain attached.

## Refresh and status

Successful replacement changes the Library version fingerprint. The next foreground refresh, pull-to-refresh, queue completion deep link, or cache validation reloads the entry; `videoUrl` then becomes available and the detail switches from YouTube embed to native OSS playback.

Failed jobs retain the original phone transcript and YouTube playback. The existing queue failure reason and retry control are reused; retry keeps `mode` and `target_library_entry_id`.

## Compatibility and security

- The schema default `mode = 'import'` keeps old mobile and desktop clients working.
- Old desktop clients may list the new fields but must not claim replacement jobs; server-side claim support/version gating prevents them from processing a mode they cannot complete atomically.
- Every enqueue and completion path uses the authenticated owner, never a client-supplied email.
- Target ownership and YouTube identity are checked both at enqueue and final replacement.
- A replacement cannot bypass per-video size or duration limits; it only avoids being counted as a new Library row.

## Acceptance criteria

- A VPN-required YouTube Library detail displays “发送到桌面端下载”; OSS-backed and non-YouTube entries do not.
- Online/offline messaging exactly follows the current 120-second desktop-presence behavior.
- Duplicate replacement taps yield one active queue job.
- A user at the Library item-count limit can replace an existing entry.
- Any pre-finalization failure leaves the original transcript, analysis, and player unchanged.
- A successful job replaces transcript and analysis, adds OSS media, preserves the Library ID and corpus links, and becomes playable without VPN.
