# Generic URL Import (desktop queue path) — Design

**Date:** 2026-05-23
**Status:** design — pending user review before plan
**Supersedes scope of:** the "Phase 3: Bilibili" line in `2026-05-23-share-to-import-design.md` (Bilibili is now the first validation source of a *generic* path, not a bespoke extractor).

## Problem / Goal

Let the user import a video from **any platform** into whatSub — not just YouTube. The user shares (or pastes) a URL; whatSub gets the **English transcript**, runs bilingual + AI-highlight analysis, self-hosts the video, and it appears in the Library on phone + desktop, watchable **without VPN**.

The trigger was Bilibili, but the realization is general: once import routes through "URL → desktop yt-dlp download → whisper → LLM → OSS → sync," the **source platform is irrelevant** — yt-dlp supports ~1800 sites, whisper transcribes any audio, OSS hosting is source-agnostic. So we build **one generic queue path** and validate it with Bilibili (the easiest non-YouTube source: China-reachable, so the desktop download has no VPN dependency).

## The two import paths (this is the architecture)

whatSub now has two import paths; the app auto-routes by source:

| | **Path 1: client-side fast lane** | **Path 2: queue (generic)** |
|---|---|---|
| Applies to | **YouTube with English captions** | **Any URL** (Bilibili, caption-less YouTube, other yt-dlp sites) |
| Text source | phone WKWebView grabs existing English captions | desktop whisper transcribes English audio |
| Compute | phone (user's LLM key) | desktop (download + whisper + LLM) |
| Needs desktop? | no | **yes (desktop must be running)** |
| Playback | YouTube embed (needs VPN) | OSS self-hosted video (**no VPN**) |
| Status | shipped (Phase 1/2) | **this spec** (mostly reuses existing pieces) |

**Routing rule:** YouTube URL → try Path 1 (fast, no desktop); on caption-extraction failure → fall back to Path 2. Any non-YouTube URL → Path 2 directly (skip caption extraction — e.g. Bilibili's CC tracks are Chinese/burned-in, useless as an English source).

## Precise boundary (do not over-promise "any platform")

Path 2 works for a URL iff:
1. **yt-dlp supports the site** (most mainstream sites do),
2. **the desktop's network can reach it** (YouTube needs the user's VPN; Bilibili/CN sites are direct; most foreign sites need VPN — the *desktop's* network, not the backend's),
3. **cookies exist on the desktop if the site needs login** (member/age/region walls).

Plus a usefulness precondition: whisper produces an **English** transcript, so the value is "any platform's **English-audio** content." Importing Chinese-audio content yields nonsense bilingual analysis (user error; not prevented in v1).

## Key decisions (locked in brainstorming)

1. **Generic URL import via the desktop queue**, Bilibili as the first validation source. Implementation = *remove the YouTube assumptions from the existing queue path + let iOS push any URL*, NOT "add a Bilibili extractor."
2. **Cookies/login resolved desktop-side.** The phone passes only the URL. yt-dlp runs on the desktop and uses the **desktop's** cookie jar (already multi-site; Bilibili login preset already exists). Cookies are never sent from the phone (sensitive; the download + login flow both live on the desktop).
3. **Failure handling v1 = desktop-side.** When a queue item fails (e.g. "需要登录"), the desktop surfaces it (reuse the existing `friendlyError` + login flow) and the item is marked `failed`. Surfacing failure back to the phone is a **fast-follow** (login must happen on the desktop anyway).
4. **Atomic queue claim** to fix multi-desktop concurrency (see below). Stale-claim reclaim is a **fast-follow**.
5. **No new backend schema column.** Source type is **derived from `source_url`** (contains `bilibili.com`/`b23.tv` → bilibili; `youtube.com`/`youtu.be` → youtube; else other). No migration.
6. **Playback is always OSS self-hosted video (AVPlayer) for Path-2 imports** — no Bilibili player embed. A defensive guard ensures a non-YouTube entry never falls back to the (broken) YouTube embed.

## Architecture / data flow

```
Bilibili app / browser / any source
  → Share or paste  bilibili.com / b23.tv / <any> URL  into whatSub
  → iOS classifies source from the URL:
       YouTube  → Path 1 (existing); on caption failure → push to queue
       non-YT   → Path 2 directly (skip caption extraction)
  → POST /api/library/import-queue { url }            [EXISTING endpoint]
     UI shows "已推送到桌面，桌面端打开后自动处理"          [EXISTING .pushedToDesktop state]

Desktop (running) — existing importQueue.ts poll worker:
  → claim oldest pending ATOMICALLY (NEW: see "Concurrency")
  → import_video (yt-dlp download, desktop cookie jar if needed) → whisper → English SRT
  → runInBackground (user's LLM key) → analysis.json
  → library_sync_to_cloud → ffmpeg thumb + OSS upload mp4 → POST /api/library/sync
       (videoKey + thumbData; youtube_id = stable id or sha256 fallback; source_url = the real URL)
  → mark queue item done (or failed + error message)

iOS Library:
  → entry has videoUrl(OSS CDN) → AVPlayer (no VPN, local ffmpeg thumb)
  → guard: source != youtube && videoUrl == nil → "请在桌面端查看" placeholder (never YouTube embed)
```

## Changes per repo

### Backend (`whatsub-license`) — small

- **Atomic claim — 方案 A, conditional update** (chosen; the only required logic change). The bug today is that `setImportStatus` (`db.ts:1896-1908`) updates **unconditionally** (`WHERE id=$1 AND owner_email=$2`, no status guard), so two desktops both "win" the same item. Fix by making the pending→processing transition conditional and reporting whether the caller won (model after the existing order claim at `db.ts:515-522`):
  ```sql
  UPDATE import_queue SET status='processing', updated_at=$now
   WHERE id=$1 AND owner_email=$2 AND status='pending'
   RETURNING id;          -- 0 rows = another instance already claimed it
  ```
  Surface this as a `claimImportItem(id, ownerEmail) -> boolean` in `db.ts` and a route the desktop calls (either a new `POST /api/library/import-queue/:id/claim`, or extend the existing `:id/status` handler to return rows-affected for the pending→processing case). The desktop only proceeds if it won the claim.
- **(Optional, more robust) 方案 B**: a single "claim oldest pending" statement with `FOR UPDATE SKIP LOCKED` (`UPDATE … WHERE id=(SELECT id … ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING *`). More elegant for many workers, but 方案 A is sufficient for the realistic 2–3 desktop case — leave B as a noted upgrade, not v1.
- **No schema change.** `import_queue` and `library_entries` already store generic `url`/`source_url`; `youtube_id` (`types.ts:167-184`) stays as a generic id holder. OSS (`oss.ts` `videoKeyFor`/`signCdnUrl`) is already source-agnostic. `enqueueImport` (`db.ts:1827`) already dedups same-URL re-enqueue.

### Desktop (`Get_Video/client`) — small

- **Use the atomic claim**: today `processNextPendingItem` (`importQueue.ts:71-80`) does `listPending()` → pick oldest → `setStatus("processing")` (the unconditional update = double-pick). Change the "mark processing" to the conditional claim above and **only proceed if the claim was won** (rows=1); if lost, return and let the next tick re-poll. (`listPending` may still be used to find the candidate id; the *claim* is what's atomic.)
- **Bilibili id**: in `core/ids.rs`, add `id_from_bilibili_url()` extracting the `BVxxxxxxxxxx` id (else keep the existing `u_<sha256>` fallback so *any* URL still gets a stable id). Used for the entry id / dedup.
- **Verify (not necessarily change) the generic download path**: confirm `import_video` (the same command the queue worker calls) downloads Bilibili via yt-dlp using the desktop cookie jar, ffmpeg-thumbs it, and `library_sync_to_cloud` OSS-uploads the mp4 + thumbData. Fix any YouTube-only assumption found (e.g. a thumbnail URL hardcoded to `i.ytimg.com`).
- **Failure surfacing (v1, desktop-side)**: when a queue item fails with a login/member error, route it through the existing `friendlyError` so the desktop shows "登录 X 后重试"; the item stays `failed` with the message (already stored via `setStatus(id,"failed",msg)`, `importQueue.ts:141`).

### iOS (`whatsub-mobile`) — small

- **Source classifier**: a tiny helper `VideoSource.from(url) -> .youtube | .bilibili | .other` (regex on host). Reuses/extends `Corpus/YouTubeID.swift` patterns.
- **Import routing** (`Import/ImportViewModel.swift`): if source != youtube → skip `CaptionExtractor`, go straight to `pushToDesktop` (existing `WhatsubAPI.enqueueImport`) → `.pushedToDesktop` state. YouTube path unchanged (try captions, fall back to push).
- **Import field copy** (`Import/ImportView.swift`): hint accepts "YouTube / B站 / 其它视频链接".
- **Share Extension** (`whatsub-share/ShareViewController.swift`): confirm it accepts any `public.url` (not YouTube-filtered) and writes it to the App Group. (Likely already generic — verify.)
- **Playback guard** (`Library/LibraryDetailView.swift:45-77`): decision becomes — `videoUrl != nil` → `VideoPlayerView` (any source); else if source==youtube → `YouTubeEmbedView`; else → a "请在桌面端查看" placeholder. Never feed a non-YouTube id to `YouTubeEmbedView`.
- **DTO**: no required change (`youtubeId`/`videoUrl` suffice; source is derived from `sourceUrl`). Add `sourceUrl`-derived source to the list/detail view models if not already present.
- **(Optional) source label** on the Library card: "B站" / "YouTube" small pill alongside the existing 免VPN/需VPN badge.

## Error handling

- **Unsupported / unreachable site / no cookies** → yt-dlp errors → queue item `failed` + message; desktop shows `friendlyError` (login action for known sites). Phone shows the item was pushed; failure detail on phone is fast-follow.
- **Concurrent desktops** → atomic claim guarantees exactly one processes each item.
- **Desktop crashes mid-claim** → item stuck in `processing` (v1 accepted limitation; stale-reclaim sweep is fast-follow).
- **Chinese-audio video imported** → bilingual analysis is nonsense; not prevented (user error).

## Out of scope (fast-follows, not v1)

- Surfacing queue **failure status on the phone** ("桌面端需登录 B站").
- **Stale-claim reclaim** (processing > N min → back to pending).
- **Backend-side worker** (server runs yt-dlp+whisper so phone-only users don't need the desktop) — bigger infra (whisper on the ECS); revisit after the desktop path is proven.
- **Bilibili player embed** (not needed — OSS self-hosted playback covers it).
- Per-source nicety beyond id + label.

## Risks

1. **yt-dlp Bilibili reliability / cookie need** — some videos need login; mitigated by the existing desktop login flow + failure surfacing. Verify the queue worker inherits cookie handling.
2. **OSS storage growth** — generic import → more videos hosted (16 GB free today). Acceptable for now; quota/cleanup is a separate future item.
3. **Desktop dependency** — Path 2 needs the desktop running; this is the trade-off of the chosen design (vs a backend worker). Communicated via the "已推送到桌面" UX.

## Testing

- **Backend**: unit-test the atomic claim — two concurrent `claim` calls on a one-item queue return the item to exactly one caller (pg-mem or a transaction test). Test `id_from_bilibili_url` parsing.
- **Desktop**: `core/ids.rs` unit tests for BV-id extraction + fallback. Manual: push a Bilibili URL → desktop downloads + whispers + syncs → appears in Library.
- **iOS**: unit-test `VideoSource.from(url)` (youtube/bilibili/other fixtures). Manual end-to-end: paste a Bilibili URL on the phone → "已推送到桌面" → (desktop processes) → entry appears → plays via AVPlayer, no VPN.
- **Concurrency**: run two desktop instances (or two `claim` calls) against the same queue → confirm no double download.
