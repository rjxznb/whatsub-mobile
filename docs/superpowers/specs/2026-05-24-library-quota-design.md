# Library Sync Quota (OSS-video cap) — Design

**Date:** 2026-05-24
**Status:** design — pending user review before plan

## Problem / Goal

Cloud-synced **OSS-hosted videos** are the only thing in whatSub that costs ongoing money (Aliyun OSS storage + CDN). Today there's **no per-user cap** → OSS can grow unbounded. Add a per-user quota on OSS videos to (a) bound OSS cost and (b) make "more cloud storage" a reason to buy the desktop license.

## Key decisions (agreed in brainstorming)

1. **Count OSS videos only** — entries with `video_key` (the actual OSS objects). Captions-only entries (iOS YouTube imports, no OSS) don't count.
2. **Tiers tied to the EXISTING desktop license** — free (no license) = **3**; `hasActiveLicense` = **50** (a HARD cap, not unlimited → bounded ~2.5 GB/user). **No iOS in-app purchase / no new entitlement system.**
3. **Why license-gated (not an iOS subscription):** OSS videos can only be created by a **licensed desktop** (desktop yt-dlp → transcode → OSS upload; iOS in-app import is captions-only; the iOS push path also needs the desktop). A user without a desktop license can't fill OSS at all, so there's nothing to sell them on storage. Reuse `hasActiveLicense` (already set by `requireSession`). See `feedback-monetization-oss-quota` memory.
4. **Server-enforced, and checked EARLY — at push time, not only at sync.** Enforcing only at `POST /api/library/sync` would let a phone-push run the whole desktop pipeline (yt-dlp download + whisper + LLM) and only get rejected at the final sync — wasting all that work. So also enforce at `POST /api/library/import-queue` (the push), counting **synced videos + in-flight queue items** so a user can't over-push. The phone is told "已满" immediately and nothing is pushed/processed. `POST /sync` keeps a backstop check (desktop-direct imports + rare cross-path races). Client caps are bypassable; the point is protecting OSS.
5. **Hard block on a NEW over-limit video; re-sync of an existing video always allowed** (it replaces the same OSS object — no net increase). Deleting a synced video frees a slot.
6. **Grandfather existing over-cap users**: never retroactively delete; just block NEW syncs until they're back under the cap.

## Architecture / components

### Backend (`whatsub-license`) — the core, protects OSS
- `db.ts`: add `ownerVideoCount(ownerEmail) -> number` (`COUNT(*) WHERE owner_email=$1 AND video_key IS NOT NULL`), `entryHasVideoKey(id, ownerEmail) -> boolean` (does the existing row already have a `video_key`?), and `pendingImportCount(ownerEmail) -> number` (`COUNT(*) FROM import_queue WHERE owner_email=$1 AND status IN ('pending','processing')` — in-flight pushes that will become OSS videos).
- `routes/library.ts` `POST /import-queue` (**push — primary early check**): before `enqueueImport`, compute `limit = c.get('hasActiveLicense') ? 50 : 3` and `committed = ownerVideoCount(email) + pendingImportCount(email)`; if `committed >= limit` → `403 { error: 'quota_exceeded', used: committed, limit }` (don't enqueue). Counting in-flight items prevents over-pushing past the cap.
- `routes/library.ts` `POST /sync` (**backstop**): before `upsertLibraryEntry`, when the payload has a `videoKey` AND the entry isn't already an OSS video (`!entryHasVideoKey`), enforce: if `ownerVideoCount(email) >= limit` → `403 { error: 'quota_exceeded', used, limit }`. Catches desktop-direct imports + the rare race where quota fills between a push and its processing.
- `routes/library.ts`: add `GET /api/library/quota` (session) → `{ used: ownerVideoCount(email), limit: hasActiveLicense ? 50 : 3 }` for clients to display usage. (Uses synced count, not in-flight.)
- `hasActiveLicense` is already on the context (`auth.ts` sets it in `requireSession`) — no new license lookup.

### Desktop (`Get_Video/client`) — where the quota error actually surfaces (desktop creates OSS videos)
- `lib/api/librarySync.ts` `friendlySyncError`: map the new `quota_exceeded` (parse `used`/`limit` from the body) → e.g. "云端视频已达上限（{used}/{limit}）。删除一些已同步的，或购买授权解锁 50 个。"
- `SyncButton.tsx`: the existing error path shows it (no structural change — it already surfaces `friendlySyncError`).
- `store/importQueue.ts`: the auto-sync worker already marks a failed queue item with the mapped error; on `quota_exceeded` the friendly message is stored (and surfaces in the iOS 导入队列 view).
- (Optional, nice-to-have) show "{used}/{limit}" in `CloudSyncManager` via `GET /quota`.

### iOS (`whatsub-mobile`) — surface the quota error on PUSH (the early check fires here)
- The phone's **push-to-desktop** (`ImportViewModel.pushToDesktop` → `WhatsubAPI.enqueueImport`) now gets a `quota_exceeded` 403 from `POST /import-queue` when the user is full. Map it to a clear Chinese message and show it instead of "已推送到桌面" — e.g. set a `.error("云端已满（{used}/{limit}）：先在 Library 删一个，或购买授权解锁 50 个")` state. (`WhatsubAPI.enqueueImport` currently ignores the response body; it needs to detect the 403 + parse `used`/`limit`.)
- iOS in-app import sync (captions-only, no `videoKey`) never hits the quota — no change needed there beyond generic error mapping.
- Optionally show "{used}/{limit}" somewhere (e.g. the import screen) via `GET /library/quota`.

## Enforcement logic (precise)

```
POST /import-queue (push — EARLY check, before enqueue):
  const limit = c.get('hasActiveLicense') ? 50 : 3
  const committed = await db.ownerVideoCount(email) + await db.pendingImportCount(email)
  if (committed >= limit) return c.json({ error: 'quota_exceeded', used: committed, limit }, 403)
  await db.enqueueImport(...)              // only if there's room

POST /sync (backstop, before upsert):
  if (videoKey is present) {
    const alreadyVideo = await db.entryHasVideoKey(id, email)
    if (!alreadyVideo) {                     // this sync ADDS a new OSS object
      const used = await db.ownerVideoCount(email)
      const limit = c.get('hasActiveLicense') ? 50 : 3
      if (used >= limit) return c.json({ error: 'quota_exceeded', used, limit }, 403)
    }
  }
  await db.upsertLibraryEntry(...)
```
- **Push at/over cap** (synced + in-flight) → blocked immediately; phone shows the message; the desktop never downloads. ← fixes the "waste the whole pipeline then reject" flaw.
- New entry with a video, at/over cap (sync) → blocked (backstop).
- Re-syncing an existing video (same id, already has `video_key`) → `alreadyVideo` true → allowed (no net OSS change).
- Captions-only sync (`videoKey` absent) → never blocked (doesn't touch OSS).

## Edge cases
- **Captions-only iOS imports**: no `videoKey` → never count, never blocked.
- **Existing entry gaining a video** (rare none→video transition): `entryHasVideoKey` is false → treated as a new OSS object → counts toward the cap (correct).
- **At exactly the cap**: the Nth video (used == limit-1 → used after = limit) is allowed; the (limit+1)th is blocked.
- **License lost**: limit drops to 3, but existing videos aren't deleted (grandfathered) — the user just can't add new ones until under 3.
- **`hasActiveLicense` unavailable**: it's always set by `requireSession`; default to the free limit (3) if somehow undefined.

## Testing
- **Backend (unit, pg-mem):** `ownerVideoCount` counts only `video_key IS NOT NULL` for the owner; `pendingImportCount` counts pending+processing queue rows; `entryHasVideoKey` true/false; **push (`POST /import-queue`) at cap (synced + pending) → 403 `quota_exceeded`, not enqueued; under cap → enqueued**; sync at cap with a NEW videoKey → 403; re-sync existing video at cap → 200; captions-only sync at cap → 200; licensed owner gets 50 vs 3. `GET /quota` returns `{used, limit}` per license.
- **Desktop:** `friendlySyncError` maps `quota_exceeded` → the Chinese message (with used/limit). Manual: sync past the cap → SyncButton shows the limit message; queue worker marks the item failed with it.
- **iOS:** error mapping unit test (quota_exceeded → message). Manual: the 导入队列 view shows a quota-failed push with the message.
- **Manual e2e:** as a free user, sync 3 desktop videos OK, the 4th blocked with the message; buy/activate license → limit becomes 50; delete one → can sync again.

## Out of scope (deferred)
- iOS in-app purchase / a separate iOS subscription (explored + shelved — only desktop fills OSS; see the monetization memory). A future mobile-only **content** subscription (公共语料库 for no-desktop users) is a separate project.
- Total-bytes quota (we cap by count; bounded count × ~max size bounds bytes).
- A user-facing "manage storage" screen (the existing CloudSyncManager + delete already covers freeing slots).
- Recurring/web subscription billing.
