# Push-to-Desktop Import Queue (whisper for caption-less videos) — Design

**Date:** 2026-05-23
**Status:** design — pending user review before plan

## Problem / Goal

iOS client-side import only works for videos that **have captions** (it extracts the YouTube CC). For **caption-less** videos there's no transcript → import fails. The user wants: from the phone, **push such a video to the desktop**, which downloads it + **whisper-transcribes** + LLM-analyzes + syncs to the cloud → it then appears in the Library on both phone and desktop. The desktop already has this whole pipeline.

## Why not whisper on the phone

The blocker isn't whisper (whisper.cpp runs on iPhone) — it's **audio acquisition**: iOS can't download the YouTube audio stream (po_token anti-scrape + adaptive streams + no yt-dlp; the caption-intercept trick doesn't apply to media). No audio → whisper is moot. Plus whisper.cpp is a heavy native dep + large models + slow/hot on long videos. **The desktop, on the user's machine with a VPN, CAN download + whisper** — so it's the worker.

## Decision (agreed)

- **Push-to-desktop via a backend queue. Desktop AUTO-POLLS** the queue and processes silently. (vs a manual "import" list on the desktop.)
- Reuse the desktop's existing pipeline end-to-end. The phone does zero heavy work.

## Architecture

```
Phone (caption extraction failed → "无字幕")
  → "推送到桌面端处理"  → POST /api/library/import-queue { url }   (status: pending)

Backend: import_queue table, per-owner.

Desktop FRONTEND poll loop (while the app is running):
  GET /api/library/import-queue?status=pending   (every ~30s, owner's session)
  for each pending item:
    POST .../:id/status {processing}
    invoke("import_video", { req: {source_kind:"url", source_value:url, ...} })   // download + whisper transcript
    → run the EXISTING LLM analysis (backgroundAnalyses) → library entry created
    → auto library_sync_to_cloud(entry.id)                                        // → cloud
    POST .../:id/status {done}    (or {failed, error} on any step failure)

Phone: the finished video shows up in the Library list (normal cloud list) when the desktop syncs it.
```

**Key placement:** the queue consumer lives in the **desktop frontend (TS)**, not Rust — because `import_video` (Rust) does download+whisper but the **LLM analysis + sync are frontend-driven** (backgroundAnalyses.ts + SyncButton/library_sync). The poller orchestrates the existing frontend pieces headlessly.

## Components

| Unit | Responsibility |
|---|---|
| **Backend** `import_queue` table | `{ id, owner_email, url, status pending/processing/done/failed, error, created_at, updated_at }` |
| Backend `POST /api/library/import-queue` (session) | enqueue `{url}` → pending. Dedup same url+owner still pending. |
| Backend `GET /api/library/import-queue?status=` (session) | owner's items (desktop polls pending; phone may poll for status display) |
| Backend `POST /api/library/import-queue/:id/status` (session) | `{status, error?}` updates |
| **Desktop** queue poller (`src/store/importQueue.ts` or similar) | interval poll while running → drive import_video → analysis → auto-sync → mark status. Skips if no auth/offline. Concurrency = 1 (one at a time). |
| Desktop reuse | `import_video` (Rust), `backgroundAnalyses` (analysis), `library_sync_to_cloud` (sync) — all exist. |
| **Phone** ImportView | on extraction failure, offer "推送到桌面端处理" → `WhatsubAPI.enqueueImport(url)`. Show "已推送，桌面端在线时会自动处理". |
| Phone (optional) | a "云端待导入" status row (poll the queue) showing pending/processing/failed — v1 can skip; the video just appears in Library when done. |

## What the user must do
- Nothing in the Apple portal. Backend schema deploy (a new table) + the desktop must be **running + logged in** to process. Set expectations: it's async — the desktop processes when it's on.

## Risks
1. **Desktop frontend orchestration**: wiring a headless poller to drive `import_video` → analysis → auto-sync (which are normally UI-driven with progress events) is the main effort. Must run without the ImportModal UI + auto-trigger sync on "ready". Reuses existing functions but needs careful sequencing + error handling per step.
2. **Desktop must be online** to process (inherent to the design; communicate clearly on the phone).
3. **Failures** (video unavailable, whisper fails, LLM error): mark the queue item `failed` with a reason; surface it (phone status view or desktop notification) so the user isn't left wondering.
4. **Duplicate/idempotency**: re-enqueue of an in-flight URL should dedup; a `done` item shouldn't reprocess.

## Phasing
- **A (backend):** import_queue table + 3 endpoints + tests + deploy.
- **B (desktop):** the poll-loop orchestrator (poll → import_video → analysis → auto-sync → status). The meaty part.
- **C (phone):** "推送到桌面" on the caption-less failure path + `enqueueImport` API. (+ optional status view.)

## Out of scope (v1)
- On-device whisper (not viable — audio acquisition).
- Live progress of the desktop job on the phone (just final appearance in Library; maybe a coarse pending/failed status).
- Non-YouTube sources in the queue (Bilibili = Phase 3).

## Testing
- Backend: enqueue/list/status endpoints (pg-mem) + dedup.
- Desktop: the orchestrator's step sequencing (mock the invoke/analysis/sync) + status transitions + failure marking.
- End-to-end: phone pushes a caption-less YouTube URL → desktop (running) auto-processes → video appears in Library with whisper transcript + analysis.
