# Self-Hosted Video Playback (OSS + CDN + native AVPlayer) — Design

**Date:** 2026-05-22
**Status:** design — pending user review before plan

## Problem

The iOS Library detail embeds YouTube via WKWebView + IFrame Player API. In mainland China this needs a VPN, and the app's core interaction — tapping a subtitle cue to seek — re-buffers through Google's CDN over the VPN, so every seek stalls. Bad UX for a subtitle-driven reader.

## Goal

Play each synced Library video from the user's own **Aliyun OSS via CDN** with a **native iOS AVPlayer**. China-reachable (no VPN), HTTP-Range seeking is near-instant, and the subtitle-follow + tap-to-seek interactions become smooth.

## Decisions (agreed)

- **Reuse the existing Enghub OSS bucket** with a `whatsub/` key prefix (same total cost as a new bucket; zero new infra — the Enghub CDN domain + A-type URL 鉴权 already cover it). Migrate to a dedicated bucket later only if cost attribution matters.
- **Reuse the Enghub CDN domain + A-type `auth_key` signing** (`CDN_BASE_URL` / `CDN_AUTH_KEY`). 2-hour signed-URL TTL.
- **Private bucket + signed CDN URLs** — videos are copyright-sensitive; not publicly enumerable, per-request signed.
- **Desktop transcodes `source.mp4` → 720p H.264** (ffmpeg) before upload — halves bandwidth, mobile-appropriate.
- **Presigned-PUT direct upload** — the desktop uploads straight to OSS via a backend-issued presigned URL (Rust `reqwest`); the backend never proxies the bytes and OSS credentials never leave the server. (Ports Enghub's `createPresignedPutUrl`.)
- **iOS: AVPlayer when `videoUrl` is present, else fall back to the existing YouTube embed** — backward-compatible during the transition; entries synced before this feature keep working.
- **No CORS configuration needed** — native AVPlayer and Rust `reqwest` are not browsers, so no CORS preflight. (OSS bucket CORS would only matter for browser-origin upload/fetch.)

## Architecture

```
Desktop (Get_Video/client), on ☁️ sync:
  {video_dir}/source.mp4
    --(ffmpeg: 720p H.264, AAC, faststart)--> {video_dir}/mobile.mp4
  POST /api/library/upload-url {id, contentType:"video/mp4"}  → { putUrl, videoKey }
  reqwest PUT mobile.mp4 → putUrl   (direct to OSS, no backend proxy)
  POST /api/library/sync { ...existing fields..., videoKey }

Backend (whatsub-license, Hono):
  library_entries + video_key TEXT (nullable)
  OSS signer (ali-oss): createPresignedPutUrl + signCdnUrl (A-type auth_key)
  POST /api/library/upload-url (session): key = whatsub/library/{ownerHash}/{id}.mp4
  POST /api/library/sync: store videoKey → video_key
  GET /list & /entry: when video_key present, add  videoUrl = signCdnUrl(video_key)  (2h TTL)

iOS (whatsub-mobile):
  LibraryEntryDetail + videoUrl: String?
  if videoUrl != nil → AVPlayerView (native): periodic time-observer → vm.onPlayerTime(sec);
       cue tap → vm.seek → player.seek(to:)
  else → existing YouTubeEmbedView (unchanged)
```

## Components & responsibilities

### Backend (`whatsub-license`)
- **`src/lib/oss.ts`** (new) — `ali-oss` client wrapper: `createPresignedPutUrl(key, contentType)` (public-endpoint signed PUT) + `signCdnUrl(key)` (A-type `auth_key` MD5, 2h TTL). Direct port of Enghub's `OssStorageService` methods. Reads env `OSS_REGION/OSS_ACCESS_KEY_ID/OSS_ACCESS_KEY_SECRET/OSS_BUCKET/CDN_BASE_URL/CDN_AUTH_KEY`.
- **`schema.sql`** — `ALTER TABLE library_entries ADD COLUMN IF NOT EXISTS video_key TEXT;`
- **`src/lib/db.ts`** — `upsertLibraryEntry` stores `video_key`; `listLibraryEntriesForOwner` + `getLibraryEntry` add `videoUrl` (signed) when `video_key` present.
- **`src/routes/library.ts`** — `POST /upload-url` (session-gated): derive a stable per-owner key `whatsub/library/{sha256(email)[:16]}/{id}.mp4`, return `{ putUrl, videoKey }`. `POST /sync` accepts optional `videoKey`.

### Desktop (`Get_Video/client`)
- **`src-tauri/src/pipeline/ffmpeg.rs`** — `transcode_720p(app, src, dst)` helper: `ffmpeg -i source.mp4 -vf scale=-2:720 -c:v libx264 -crf 23 -preset veryfast -c:a aac -movflags +faststart mobile.mp4` (faststart = moov atom up front for progressive streaming).
- **`src-tauri/src/commands/library_sync.rs`** — in `library_sync_to_cloud`: transcode → request `upload-url` → `reqwest` PUT the file → include `videoKey` in the sync body. Best-effort: if transcode/upload fails, sync without `videoKey` (entry falls back to YouTube on iOS).

### iOS (`whatsub-mobile`)
- **`Components/VideoPlayerView.swift`** (new) — wraps `AVPlayer` (AVPlayerViewController via UIViewControllerRepresentable). Inputs mirror YouTubeEmbedView: `url`, `seek: SeekRequest?`, `onReady`, `onTime`. Uses `addPeriodicTimeObserver(forInterval: 0.25s)` → `onTime`; `seek` change → `player.seek(to:toleranceBefore:.zero, toleranceAfter:.zero)` for exact cue seeking.
- **`Networking/DTOs.swift`** — `LibraryEntryDetail` + `videoUrl: String?`.
- **`Library/LibraryDetailView.swift`** — `player(entry)`: `if let v = entry.videoUrl, let url = URL(string: v) → VideoPlayerView` else the existing `YouTubeEmbedView`. The ViewModel (`onPlayerTime`, `seek`, `currentIndex`) is unchanged — both players feed the same hooks.

## Data flow notes
- **Signed-URL expiry (2h):** iOS fetches a fresh `/entry` (with a fresh `videoUrl`) each time the detail view opens, so a stale URL is never used for a new session. A 2h TTL covers any single viewing session.
- **Key scheme:** `whatsub/library/{sha256(email)[:16]}/{id}.mp4` — per-owner namespacing, deterministic so a re-sync overwrites the same object (no orphans).
- **Range requests:** OSS + CDN serve HTTP Range by default → AVPlayer seeking works with no config.

## What the user must do (deploy-time, secrets — NOT in repo or chat)
1. Add to `/opt/whatsub/.env` on the Aliyun server (reuse the Enghub values): `OSS_REGION, OSS_ACCESS_KEY_ID, OSS_ACCESS_KEY_SECRET, OSS_BUCKET, CDN_BASE_URL, CDN_AUTH_KEY`. (The user sets these directly on the server; I never read the secret values.)
2. Bucket + CDN already exist (Enghub) — nothing to create.
3. Optional: a RAM sub-account scoped to the bucket for least-privilege.

## Security / cost
- Private bucket + 2h signed URLs → not publicly enumerable; reduces (not eliminates) copyright exposure.
- 720p transcode ≈ halves storage + CDN traffic vs source.
- Cost is usage-based (~10元/mo at current scale, scales with users = revenue).

## Out of scope (v1 of this feature)
- HLS adaptive bitrate (single 720p MP4 + Range is enough; revisit if buffering is poor on slow networks).
- Migrating existing entries automatically (user re-syncs from desktop to populate `video_key`).
- Offline download / caching in the app.
- Replacing the corpus phrase-detail YouTube embed (that's a separate, lower-frequency surface; keep YouTube there for now).

## Testing
- Backend: unit-test `signCdnUrl` (deterministic given fixed time/rand) + `upload-url`/`sync` route (presigned URL shape, videoKey stored, videoUrl appears in list/entry when key present). pg-mem.
- Desktop: `cargo build` + the existing sync tests; manual `pnpm tauri dev` re-sync.
- iOS: CI build; manual — play a synced video via AVPlayer without VPN, tap cues to seek, confirm subtitle follow.
