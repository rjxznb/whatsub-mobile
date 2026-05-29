# Audio Sidecar (.m4a) for Practice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make 跟读/听抄 first-listen near-instant on long OSS videos by uploading a small audio-only sidecar (`.m4a`, ~64 kbps mono AAC, ~3-5% of the .mp4 size) during desktop sync, and having iOS practice sheets fetch from it instead of from the full MP4.

**Architecture:** Desktop's existing `library_sync_to_cloud` already transcodes `source.mp4` → `mobile.mp4` and uploads to OSS via presigned PUT. We add one extra ffmpeg pass (`-vn -c:a aac -b:a 64k -ac 1`) that produces `mobile.m4a` (~5-10s extra per sync, ~3-5% extra OSS bytes). Backend stores the audio object key alongside the video key and surfaces a signed CDN URL in `/entry/:id` + `/list`. iOS `CueAudioPlayer` prefers the audio URL when present — practice sheets pull ~40 KB per 5s cue instead of ~1.2 MB. Old entries without an audio_key gracefully fall back to the existing shared-player path.

**Tech Stack:**
- **Backend (whatsub-license)**: Hono + Postgres + ali-oss. Tests via vitest + pg-mem.
- **Desktop (Get_Video)**: Tauri Rust + reqwest + ffmpeg sidecar.
- **iOS (whatsub-mobile)**: Swift + AVFoundation + AVPlayer (HTTP Range loading).

---

## File Structure

### whatsub-license (backend, Node + TypeScript)
- **Modify** `schema.sql` — idempotent `ALTER TABLE library_entries ADD COLUMN IF NOT EXISTS audio_key TEXT`
- **Modify** `src/lib/db.ts` — extend `SyncLibraryEntryInput`, `LibraryEntryRow`, `LibraryEntryListItem`, `upsertLibraryEntry`, `getLibraryEntry`, `listLibraryEntriesForOwner`, `deleteLibraryEntry` to round-trip `audioKey`; emit `audioUrl` (via `signCdnUrl`) in the row converters
- **Modify** `src/lib/oss.ts` — add `audioKeyFor(email, id)` helper that mirrors `videoKeyFor` shape but under a different prefix (`whatsub/library-audio/...`) so a list operation never confuses the two
- **Modify** `src/routes/library.ts`:
  - `/sync` reads optional `audioKey` from body, passes to db
  - `/upload-url` reads optional `kind: 'audio' | 'video'` (defaults `'video'`) and routes to `audioKeyFor` vs `videoKeyFor`; audio path skips the per-video size/duration check (audio file is small and timing is already validated against the video)
  - `/sync/:id DELETE` also deletes the audio object if present (best-effort OSS cleanup)
- **Modify** `tests/library-routes.test.ts` — new cases for: audioKey roundtrip in /sync + /entry; /upload-url kind=audio path; old client (no audioKey) still 200s
- **Modify** `tests/library-db.test.ts` — direct db-level audio_key persist test

### Get_Video (desktop, Tauri — Rust + TS)
- **Modify** `client/src-tauri/src/pipeline/ffmpeg.rs` — new `extract_audio_aac(app, src_mp4, dst_m4a, id)` async fn using the existing ffmpeg sidecar invocation pattern
- **Modify** `client/src-tauri/src/commands/library_sync.rs`:
  - `upload_video` becomes the caller of a new `upload_audio` helper after the video PUT succeeds; both keys returned as a tuple `(videoKey, audioKey)`
  - `library_sync_to_cloud` POSTs `audioKey` alongside `videoKey` in the `/sync` body

### whatsub-mobile (iOS, Swift)
- **Modify** `whatsub-mobile/Networking/DTOs.swift` — `LibraryEntryDetail.audioUrl: String?`, `LibraryListItem.audioUrl: String?`
- **Modify** `whatsub-mobile/Practice/CueAudioPlayer.swift` — new `init(audioURL: URL?, mainPlayer: AVPlayer?, fallbackVideoURL: URL?)`; when `audioURL` is non-nil, build a dedicated AVPlayer for the small .m4a (no buffer sharing needed); still snapshot+pause+restore `mainPlayer` when provided (so main video stays paused during practice)
- **Modify** `whatsub-mobile/Practice/ShadowSheet.swift` — accept + thread an `audioURL: URL?` init param into `CueAudioPlayer`
- **Modify** `whatsub-mobile/Practice/ClozeSheet.swift` — same
- **Modify** `whatsub-mobile/Library/LibraryDetailView.swift` — compute `ossAudioURL` next to existing `ossVideoURL`; pass to both sheets

---

## Phase A — Backend

### Task 1: schema migration

**Files:**
- Modify: `whatsub-license/schema.sql`

- [ ] **Step 1: Find the existing library_entries CREATE TABLE + the idempotent ALTER pattern**

Run: `grep -n "library_entries\|ALTER TABLE library_entries" C:/Users/renjx/Desktop/whatsub-license/schema.sql | head -20`

Expected: see the `CREATE TABLE IF NOT EXISTS library_entries (...)` block + at least one existing `ALTER TABLE library_entries ADD COLUMN IF NOT EXISTS ...` line (e.g., for `thumb_data` or `video_key`).

- [ ] **Step 2: Append the audio_key column**

In `whatsub-license/schema.sql`, after the existing idempotent `ALTER TABLE library_entries ADD COLUMN IF NOT EXISTS video_key TEXT;` line (or any of the other ADD COLUMN lines for library_entries), add:

```sql
-- Audio-only sidecar (.m4a), uploaded next to mobile.mp4 by the desktop
-- sync. Lets iOS practice modes (跟读/听抄) fetch ~3-5% of the video bytes
-- instead of pulling MP4 range requests that mostly contain video frames
-- we don't display. NULL for entries synced before 2026-05-29 — iOS falls
-- back to the video URL in that case.
ALTER TABLE library_entries ADD COLUMN IF NOT EXISTS audio_key TEXT;
```

- [ ] **Step 3: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
git add schema.sql
git commit -m "schema: add library_entries.audio_key for the .m4a sidecar"
```

---

### Task 2: db.ts — extend types + upsert + reads for audio_key

**Files:**
- Modify: `whatsub-license/src/lib/db.ts`

- [ ] **Step 1: Add audioKey to SyncLibraryEntryInput**

Find the `SyncLibraryEntryInput` interface (search for `videoKey?:` near it). Add an `audioKey?: string` line right after `videoKey?:`. Example final shape:

```ts
export interface SyncLibraryEntryInput {
  id: string;
  ownerEmail: string;
  // ...existing fields...
  videoKey?: string;
  audioKey?: string;
  now: number;
}
```

- [ ] **Step 2: Extend upsertLibraryEntry to persist audio_key**

In `db.ts` find `async upsertLibraryEntry(input: SyncLibraryEntryInput)` (around line 1732). Add `audio_key` to the INSERT column list, add `$13` to VALUES, add `audio_key = EXCLUDED.audio_key` to the ON CONFLICT UPDATE, and add `input.audioKey ?? null` as the final positional parameter:

```ts
async upsertLibraryEntry(input: SyncLibraryEntryInput): Promise<void> {
  await this.pool.query(
    `INSERT INTO library_entries
       (id, owner_email, youtube_id, source_url, title, duration_sec,
        thumb_url, transcript_srt, analysis_json, storage_location, synced_at, thumb_data, video_key, audio_key)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'inline', $10, $11, $12, $13)
     ON CONFLICT (id) DO UPDATE SET
       owner_email     = EXCLUDED.owner_email,
       youtube_id      = EXCLUDED.youtube_id,
       source_url      = EXCLUDED.source_url,
       title           = EXCLUDED.title,
       duration_sec    = EXCLUDED.duration_sec,
       thumb_url       = EXCLUDED.thumb_url,
       transcript_srt  = EXCLUDED.transcript_srt,
       analysis_json   = EXCLUDED.analysis_json,
       synced_at       = EXCLUDED.synced_at,
       thumb_data      = EXCLUDED.thumb_data,
       video_key       = EXCLUDED.video_key,
       audio_key       = EXCLUDED.audio_key`,
    [
      input.id,
      input.ownerEmail,
      input.youtubeId,
      input.sourceUrl,
      input.title,
      input.durationSec ?? null,
      input.thumbUrl ?? null,
      input.transcriptSrt,
      JSON.stringify(input.analysisJson),
      input.now,
      input.thumbData ?? null,
      input.videoKey ?? null,
      input.audioKey ?? null,
    ],
  );
}
```

- [ ] **Step 3: Add audioUrl to LibraryEntryRow + LibraryEntryListItem types**

Find the `LibraryEntryRow` interface (used by `getLibraryEntry`) and `LibraryEntryListItem` interface. Add `audioUrl: string | null` immediately after the existing `videoUrl: string | null` line in each. Example:

```ts
export interface LibraryEntryRow {
  // ...existing fields...
  videoUrl: string | null;
  audioUrl: string | null;
  // ...
}

export interface LibraryEntryListItem {
  // ...existing fields...
  videoUrl: string | null;
  audioUrl: string | null;
  // ...
}
```

- [ ] **Step 4: Extend listLibraryEntriesForOwner to read + emit audio_key**

Find `async listLibraryEntriesForOwner(...)` (around line 1777). Add `audio_key: string | null;` to the row type, `audio_key` to the SELECT, and emit `audioUrl: r.audio_key ? signCdnUrl(r.audio_key) : null` next to the existing `videoUrl` line:

```ts
async listLibraryEntriesForOwner(ownerEmail: string): Promise<LibraryEntryListItem[]> {
  const res = await this.pool.query<{
    id: string;
    youtube_id: string;
    source_url: string;
    title: string;
    duration_sec: number | null;
    thumb_url: string | null;
    has_thumb: boolean;
    video_key: string | null;
    audio_key: string | null;
    synced_at: number;
  }>(
    `SELECT id, youtube_id, source_url, title, duration_sec, thumb_url,
            thumb_data IS NOT NULL AS has_thumb, video_key, audio_key, synced_at
       FROM library_entries
      WHERE owner_email = $1
      ORDER BY synced_at DESC`,
    [ownerEmail],
  );
  return res.rows.map((r) => ({
    id: r.id,
    youtubeId: r.youtube_id,
    sourceUrl: r.source_url,
    title: r.title,
    durationSec: r.duration_sec,
    thumbUrl: r.has_thumb
      ? `https://whatsub.eversay.cc/api/library/thumb/${r.id}`
      : r.thumb_url,
    videoUrl: r.video_key ? signCdnUrl(r.video_key) : null,
    audioUrl: r.audio_key ? signCdnUrl(r.audio_key) : null,
    syncedAt: r.synced_at,
  }));
}
```

- [ ] **Step 5: Extend getLibraryEntry to read + emit audio_key**

Same pattern in `async getLibraryEntry(...)` (around line 1819). Add `audio_key: string | null;` to row type, `audio_key` to SELECT, and `audioUrl: r.audio_key ? signCdnUrl(r.audio_key) : null` to the returned object. Final shape:

```ts
async getLibraryEntry(id: string, ownerEmail: string): Promise<LibraryEntryRow | undefined> {
  const res = await this.pool.query<{
    id: string;
    owner_email: string;
    youtube_id: string;
    source_url: string;
    title: string;
    duration_sec: number | null;
    thumb_url: string | null;
    has_thumb: boolean;
    video_key: string | null;
    audio_key: string | null;
    transcript_srt: string;
    analysis_json: unknown;
    storage_location: string;
    synced_at: number;
  }>(
    `SELECT id, owner_email, youtube_id, source_url, title, duration_sec,
            thumb_url, thumb_data IS NOT NULL AS has_thumb, video_key, audio_key,
            transcript_srt, analysis_json, storage_location, synced_at
       FROM library_entries
      WHERE id = $1 AND owner_email = $2
      LIMIT 1`,
    [id, ownerEmail],
  );
  const r = res.rows[0];
  if (!r) return undefined;
  return {
    id: r.id,
    ownerEmail: r.owner_email,
    youtubeId: r.youtube_id,
    sourceUrl: r.source_url,
    title: r.title,
    durationSec: r.duration_sec,
    thumbUrl: r.has_thumb
      ? `https://whatsub.eversay.cc/api/library/thumb/${r.id}`
      : r.thumb_url,
    videoUrl: r.video_key ? signCdnUrl(r.video_key) : null,
    audioUrl: r.audio_key ? signCdnUrl(r.audio_key) : null,
    transcriptSrt: r.transcript_srt,
    analysisJson: r.analysis_json,
    storageLocation: (r.storage_location === 'oss' ? 'oss' : 'inline'),
    syncedAt: r.synced_at,
  };
}
```

- [ ] **Step 6: Extend deleteLibraryEntry to return audioKey for cleanup**

Find `async deleteLibraryEntry(id, ownerEmail)` (around line 1810). Change the RETURNING + return type to include both keys:

```ts
async deleteLibraryEntry(id: string, ownerEmail: string): Promise<{ removed: boolean; videoKey: string | null; audioKey: string | null }> {
  const res = await this.pool.query<{ video_key: string | null; audio_key: string | null }>(
    `DELETE FROM library_entries WHERE id = $1 AND owner_email = $2 RETURNING video_key, audio_key`,
    [id, ownerEmail],
  );
  const row = res.rows[0];
  return { removed: !!row, videoKey: row?.video_key ?? null, audioKey: row?.audio_key ?? null };
}
```

- [ ] **Step 7: Typecheck**

Run: `cd C:/Users/renjx/Desktop/whatsub-license && npx tsc --noEmit 2>&1 | head -40`
Expected: no errors. (If a backend route or admin route also accesses these return types and complains about `audioKey` not existing on the destructured result, that's an unrelated dirty caller — fix it by adding `audioKey` to its destructure or use `_audioKey` to mark unused.)

- [ ] **Step 8: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
git add src/lib/db.ts
git commit -m "db: round-trip audio_key on library_entries (upsert + read + delete)"
```

---

### Task 3: oss.ts — add audioKeyFor helper

**Files:**
- Modify: `whatsub-license/src/lib/oss.ts`

- [ ] **Step 1: Add audioKeyFor right after videoKeyFor**

In `whatsub-license/src/lib/oss.ts` find the existing `export function videoKeyFor(...)` at the bottom of the file. Append:

```ts
/** Deterministic per-owner object key for the audio sidecar. Different prefix
 *  from videoKeyFor so an OSS list-by-prefix never mixes the two; same
 *  owner-hash scheme so the key is reproducible from (email, id) alone. */
export function audioKeyFor(email: string, id: string): string {
  const ownerHash = createHash('sha256').update(email).digest('hex').slice(0, 16);
  return `whatsub/library-audio/${ownerHash}/${id}.m4a`;
}
```

- [ ] **Step 2: Add an oss.test.ts case**

In `whatsub-license/tests/oss.test.ts` add a new test alongside the existing `videoKeyFor` test:

```ts
it('audioKeyFor is deterministic + uses a separate prefix from videoKeyFor', async () => {
  const { audioKeyFor, videoKeyFor } = await import('../src/lib/oss.js');
  const v = videoKeyFor('x@y.com', 'vid');
  const a = audioKeyFor('x@y.com', 'vid');
  expect(a).toBe(audioKeyFor('x@y.com', 'vid')); // deterministic
  expect(a).toMatch(/^whatsub\/library-audio\/[0-9a-f]{16}\/vid\.m4a$/);
  expect(a).not.toBe(v);
  expect(a.split('/')[1]).not.toBe(v.split('/')[1]); // distinct prefix
});
```

- [ ] **Step 3: Run the test**

Run: `cd C:/Users/renjx/Desktop/whatsub-license && npx vitest run tests/oss.test.ts 2>&1 | tail -6`
Expected: 3 tests passed (the existing 2 + the new one).

- [ ] **Step 4: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
git add src/lib/oss.ts tests/oss.test.ts
git commit -m "oss: add audioKeyFor (separate prefix from videoKeyFor)"
```

---

### Task 4: routes/library.ts — /sync accepts audioKey

**Files:**
- Modify: `whatsub-license/src/routes/library.ts`
- Modify: `whatsub-license/tests/library-routes.test.ts`

- [ ] **Step 1: Write the failing test FIRST**

In `whatsub-license/tests/library-routes.test.ts`, find the existing `describe('POST /api/library/sync', ...)` block and add this test inside it:

```ts
it('persists audioKey when provided in the request body', async () => {
  const rig = makeApp();
  const token = await insertSessionFor(rig.db, 'alice@example.com');
  const res = await rig.app.request('/api/library/sync', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      ...VALID_BODY,
      id: 'auk1',
      videoKey: 'whatsub/library/abc/auk1.mp4',
      audioKey: 'whatsub/library-audio/abc/auk1.m4a',
    }),
  });
  expect(res.status).toBe(200);
  // Server reflects audioKey back via /entry/:id (signed CDN URL when audio_key present)
  const entry = await (await rig.app.request('/api/library/entry/auk1', {
    headers: { authorization: `Bearer ${token}` },
  })).json() as any;
  expect(entry.audioUrl).toContain('https://cdn.example.com/whatsub/library-audio/abc/auk1.m4a?auth_key=');
});

it('omitting audioKey is fine — old desktop clients still 200 + audioUrl is null', async () => {
  const rig = makeApp();
  const token = await insertSessionFor(rig.db, 'alice@example.com');
  const res = await rig.app.request('/api/library/sync', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...VALID_BODY, id: 'auk2', videoKey: 'whatsub/library/abc/auk2.mp4' }),
  });
  expect(res.status).toBe(200);
  const entry = await (await rig.app.request('/api/library/entry/auk2', {
    headers: { authorization: `Bearer ${token}` },
  })).json() as any;
  expect(entry.audioUrl).toBeNull();
});
```

- [ ] **Step 2: Run the new tests — they should fail**

Run: `cd C:/Users/renjx/Desktop/whatsub-license && npx vitest run tests/library-routes.test.ts 2>&1 | grep -E "audioKey|audioUrl|FAIL" | head -10`
Expected: at least one FAIL — `entry.audioUrl` will be undefined since the route doesn't pass audioKey through yet.

- [ ] **Step 3: Update /sync to parse + forward audioKey**

In `whatsub-license/src/routes/library.ts` find the `/sync` route (around line 22). Inside it, after the existing line `const videoKey = typeof body.videoKey === 'string' ? body.videoKey : undefined;` add:

```ts
const audioKey = typeof body.audioKey === 'string' ? body.audioKey : undefined;
```

Then in the `db.upsertLibraryEntry({ ... })` call near the bottom of the route, after the `videoKey,` line add:

```ts
audioKey,
```

The full edit area looks like:

```ts
const videoKey = typeof body.videoKey === 'string' ? body.videoKey : undefined;
const audioKey = typeof body.audioKey === 'string' ? body.audioKey : undefined;
// ... existing limits / count checks ...
await db.upsertLibraryEntry({
  id,
  ownerEmail: email,
  // ... existing fields ...
  videoKey,
  audioKey,
  transcriptSrt,
  analysisJson,
  now: Date.now(),
});
```

- [ ] **Step 4: Run tests — should pass now**

Run: `cd C:/Users/renjx/Desktop/whatsub-license && npx vitest run tests/library-routes.test.ts 2>&1 | tail -6`
Expected: all tests pass (the 2 new + all existing).

- [ ] **Step 5: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "/sync: accept optional audioKey; surface as audioUrl in /entry"
```

---

### Task 5: routes/library.ts — DELETE /sync/:id cleans up audio object

**Files:**
- Modify: `whatsub-license/src/routes/library.ts`
- Modify: `whatsub-license/tests/library-routes.test.ts`

- [ ] **Step 1: Write the failing test**

In `whatsub-license/tests/library-routes.test.ts` add:

```ts
it('DELETE /sync/:id returns audioKey + videoKey for cleanup', async () => {
  const rig = makeApp();
  const token = await insertSessionFor(rig.db, 'alice@example.com');
  await rig.app.request('/api/library/sync', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      ...VALID_BODY,
      id: 'del-a1',
      videoKey: 'whatsub/library/abc/del-a1.mp4',
      audioKey: 'whatsub/library-audio/abc/del-a1.m4a',
    }),
  });
  const res = await rig.app.request('/api/library/sync/del-a1', {
    method: 'DELETE',
    headers: { authorization: `Bearer ${token}` },
  });
  expect(res.status).toBe(200);
  // Entry is gone
  const g = await rig.app.request('/api/library/entry/del-a1', { headers: { authorization: `Bearer ${token}` } });
  expect(g.status).toBe(404);
});
```

- [ ] **Step 2: Update the DELETE route to call deleteObject(audioKey) too**

In `whatsub-license/src/routes/library.ts` find the `app.delete('/sync/:id', ...)` route. The current code destructures `{ removed, videoKey }` — update to also pick `audioKey` and best-effort delete it:

```ts
app.delete('/sync/:id', requireSession(db), async (c) => {
  const email = c.get('email' as never) as string;
  const id = c.req.param('id');
  if (!id) return c.json({ error: 'invalid_input' }, 400);
  const { removed, videoKey, audioKey } = await db.deleteLibraryEntry(id, email);
  if (!removed) return c.json({ error: 'not_found' }, 404);
  if (ossConfigured()) {
    if (videoKey) await deleteObject(videoKey); // best-effort OSS video cleanup
    if (audioKey) await deleteObject(audioKey); // best-effort OSS audio sidecar cleanup
  }
  return c.json({ ok: true });
});
```

- [ ] **Step 3: Run tests**

Run: `cd C:/Users/renjx/Desktop/whatsub-license && npx vitest run tests/library-routes.test.ts 2>&1 | tail -6`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "DELETE /sync/:id: also clean up the OSS audio sidecar"
```

---

### Task 6: routes/library.ts — /upload-url routes kind=audio to audioKeyFor

**Files:**
- Modify: `whatsub-license/src/routes/library.ts`
- Modify: `whatsub-license/tests/library-routes.test.ts`

- [ ] **Step 1: Write the failing test**

In `whatsub-license/tests/library-routes.test.ts` add inside the existing `describe('video upload-url + videoUrl', ...)` block:

```ts
it('POST /upload-url with kind=audio returns an audioKey under library-audio/', async () => {
  const rig = makeApp();
  const token = await insertSessionFor(rig.db, 'alice@example.com');
  const res = await rig.app.request('/api/library/upload-url', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: 'smoke-aud', kind: 'audio', contentType: 'audio/mp4' }),
  });
  expect(res.status).toBe(200);
  const body = (await res.json()) as { putUrl: string; audioKey: string };
  expect(body.audioKey).toMatch(/^whatsub\/library-audio\/[0-9a-f]{16}\/smoke-aud\.m4a$/);
  expect(typeof body.putUrl).toBe('string');
  expect(body.putUrl.length).toBeGreaterThan(0);
});

it('POST /upload-url with kind=audio + huge contentLength is NOT 413 (audio is small; limits gate only video)', async () => {
  const rig = makeApp();
  const token = await insertSessionFor(rig.db, 'alice@example.com');
  const res = await rig.app.request('/api/library/upload-url', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: 'big-aud', kind: 'audio', contentType: 'audio/mp4', contentLength: 999_999_999 }),
  });
  expect(res.status).toBe(200); // audio skips video size cap
});
```

- [ ] **Step 2: Update /upload-url to route on `kind`**

In `whatsub-license/src/routes/library.ts` find the `/upload-url` route (around line 131). Add an `audioKeyFor` to the existing oss import line at the top of the file:

```ts
import { audioKeyFor, createPresignedPutUrl, deleteObject, getObjectSize, ossConfigured, videoKeyFor } from '../lib/oss.js';
```

Then update the route body to support `kind`:

```ts
app.post('/upload-url', requireSession(db), async (c) => {
  const email = c.get('email' as never) as string;
  let body: Record<string, unknown>;
  try { body = (await c.req.json()) as Record<string, unknown>; }
  catch { return c.json({ error: 'invalid_json' }, 400); }
  const id = typeof body.id === 'string' ? body.id.trim() : '';
  const kind = body.kind === 'audio' ? 'audio' : 'video';
  const contentType = typeof body.contentType === 'string'
    ? body.contentType
    : (kind === 'audio' ? 'audio/mp4' : 'video/mp4');
  // contentLength/durationSec early-fail checks only apply to video — audio
  // is small (~5% of the video) and timing was already validated against the
  // video PUT call (the audio is just a different encoding of the same source).
  const contentLength =
    typeof body.contentLength === 'number' && Number.isFinite(body.contentLength)
      ? Math.floor(body.contentLength) : undefined;
  const durationSec =
    typeof body.durationSec === 'number' && Number.isFinite(body.durationSec)
      ? Math.floor(body.durationSec) : undefined;
  if (!id) return c.json({ error: 'invalid_input' }, 400);
  if (!ossConfigured()) return c.json({ error: 'oss_not_configured' }, 503);
  if (kind === 'video') {
    const limits = await getLibraryLimits(db, email, Date.now());
    if (contentLength !== undefined && contentLength > limits.maxVideoBytes) {
      return c.json({ error: 'video_too_large', bytes: contentLength, limit: limits.maxVideoBytes }, 413);
    }
    if (durationSec !== undefined && durationSec > limits.maxVideoSeconds) {
      return c.json({ error: 'video_too_long', duration: durationSec, limit: limits.maxVideoSeconds }, 413);
    }
    const videoKey = videoKeyFor(email, id);
    const putUrl = await createPresignedPutUrl(videoKey, contentType);
    return c.json({ putUrl, videoKey });
  } else {
    const audioKey = audioKeyFor(email, id);
    const putUrl = await createPresignedPutUrl(audioKey, contentType);
    return c.json({ putUrl, audioKey });
  }
});
```

- [ ] **Step 3: Run tests**

Run: `cd C:/Users/renjx/Desktop/whatsub-license && npx vitest run tests/library-routes.test.ts 2>&1 | tail -6`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "/upload-url: route kind=audio to audioKeyFor (skips video size/duration caps)"
```

---

### Task 7: Run full backend test suite + tsc

**Files:** (read-only verification)

- [ ] **Step 1: Type-check the whole backend**

Run: `cd C:/Users/renjx/Desktop/whatsub-license && npx tsc --noEmit 2>&1 | tail -10`
Expected: no errors.

- [ ] **Step 2: Run all vitest tests**

Run: `cd C:/Users/renjx/Desktop/whatsub-license && npx vitest run 2>&1 | tail -8`
Expected: all tests pass (the existing 439 + ~5 new = ~444).

- [ ] **Step 3: If any pre-existing test broke, fix it inline (the route signatures shouldn't have changed for backward compat, but the deleteLibraryEntry return type added a field — any caller destructuring `{ removed, videoKey }` will keep compiling; only assertions on the EXACT shape `{removed, videoKey}` would break).** No commit needed if everything green.

---

### Task 8: Deploy backend to prod

**Files:** (no code changes)

- [ ] **Step 1: Push the backend commits**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
git push origin main
```

- [ ] **Step 2: Apply schema migration on the prod Postgres**

The schema change is an idempotent ADD COLUMN IF NOT EXISTS — safe to apply before the new image starts. Run:

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 'docker exec -i enghub-postgres-1 psql -U whatsub_license_user -d whatsub_license -c "ALTER TABLE library_entries ADD COLUMN IF NOT EXISTS audio_key TEXT;"'
```

Expected: `ALTER TABLE` printed (or no output if already applied).

- [ ] **Step 3: Build the docker image**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
docker buildx build --load -t whatsub-license:latest .
```

Expected: build finishes with `naming to docker.io/library/whatsub-license:latest done`.

- [ ] **Step 4: Save + scp + load + recreate**

```bash
docker save whatsub-license:latest -o $env:TEMP/whatsub-license.tar
scp -i ~/.ssh/id_ed25519 $env:TEMP/whatsub-license.tar root@47.93.87.206:/tmp/whatsub-license.tar
scp -i ~/.ssh/id_ed25519 $env:TEMP/deploy.sh root@47.93.87.206:/tmp/deploy.sh
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "sed -i 's/\r$//' /tmp/deploy.sh; bash /tmp/deploy.sh"
```

Expected: `Container whatsub-license Started` + log line `whatsub-license listening on :3002`.

- [ ] **Step 5: Verify on prod**

Smoke-test the demo account's /entry to confirm backward compat (audioUrl should be null for an existing entry without audio_key):

```bash
$base = "https://whatsub.eversay.cc"
$login = Invoke-RestMethod -Uri "$base/api/license/auth/verify-code" -Method Post -ContentType "application/json" -Body '{"email":"appreview@eversay.cc","code":"424242"}'
$token = $login.sessionToken
# List existing entries — verify audioUrl field is present (as null)
Invoke-RestMethod -Uri "$base/api/library/list" -Headers @{Authorization="Bearer $token"} | ConvertTo-Json -Depth 4 | Select-String "audioUrl"
```

Expected: at least one `"audioUrl": null` line in the output.

---

## Phase B — Desktop (Get_Video)

### Task 9: pipeline/ffmpeg.rs — extract_audio_aac helper

**Files:**
- Modify: `Get_Video/client/src-tauri/src/pipeline/ffmpeg.rs`

- [ ] **Step 1: Find the existing transcode_720p function for the sidecar invocation pattern**

Run: `grep -n "fn transcode_720p\|tauri_plugin_shell\|sidecar(" C:/Users/renjx/Desktop/Get_Video/client/src-tauri/src/pipeline/ffmpeg.rs | head -10`
Expected: see the existing async fn that constructs an ffmpeg sidecar command. The new function will mirror its shape (use `app.shell().sidecar("ffmpeg")`, spawn, await output).

- [ ] **Step 2: Add extract_audio_aac next to transcode_720p**

In `Get_Video/client/src-tauri/src/pipeline/ffmpeg.rs` add a new public async fn after `transcode_720p`. Concrete shape (mirror `transcode_720p`'s signature for the AppHandle + path inputs + id; drop the duration/progress callbacks since audio extraction is fast and not user-facing as % progress):

```rust
/// Extract a small mono AAC sidecar (.m4a) from a transcoded mp4. Used by
/// `library_sync_to_cloud` so iOS practice modes can fetch ~3-5% of the
/// bytes (just audio) instead of pulling MP4 range requests that mostly
/// contain video frames they don't display. Fast — ~5-10s for a 30-min
/// video on a typical laptop because it re-encodes audio only.
pub async fn extract_audio_aac<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    src_mp4: &std::path::Path,
    dst_m4a: &std::path::Path,
    id: &str,
) -> Result<(), String> {
    use tauri_plugin_shell::ShellExt;
    let cmd = app
        .shell()
        .sidecar("ffmpeg")
        .map_err(|e| format!("ffmpeg sidecar: {e}"))?
        .args([
            "-y",
            "-i",
            src_mp4.to_string_lossy().as_ref(),
            "-vn",           // no video
            "-c:a", "aac",   // AAC encoder
            "-b:a", "64k",   // 64 kbps bitrate
            "-ac", "1",      // mono
            "-movflags", "+faststart", // moov atom at the front for fast range-fetch startup
            dst_m4a.to_string_lossy().as_ref(),
        ]);
    let (mut rx, _child) = cmd.spawn().map_err(|e| format!("ffmpeg spawn: {e}"))?;
    let mut stderr_tail = String::new();
    while let Some(event) = rx.recv().await {
        if let tauri_plugin_shell::process::CommandEvent::Stderr(line) = event {
            // ffmpeg writes progress to stderr; keep the tail for error context
            stderr_tail = String::from_utf8_lossy(&line).into_owned();
        } else if let tauri_plugin_shell::process::CommandEvent::Terminated(payload) = event {
            if payload.code.unwrap_or(-1) != 0 {
                return Err(format!(
                    "ffmpeg extract_audio_aac[{id}] exit={}: {}",
                    payload.code.unwrap_or(-1),
                    stderr_tail
                ));
            }
            return Ok(());
        }
    }
    Err(format!("ffmpeg extract_audio_aac[{id}] terminated without status"))
}
```

> Note: the EXACT spawn / event handling shape should match what `transcode_720p` already does in this file — if `transcode_720p` uses a slightly different `tauri_plugin_shell` import path or event enum, use the same pattern here. The body above is the canonical Tauri v2 sidecar pattern; if Get_Video uses a custom wrapper, prefer that.

- [ ] **Step 3: Compile-check**

Run: `cd C:/Users/renjx/Desktop/Get_Video/client/src-tauri && cargo check --message-format=short 2>&1 | grep -E "error|^warning: unused" | head -20`
Expected: no errors. Any pre-existing `unused import` warnings are fine.

- [ ] **Step 4: Commit**

```bash
cd C:/Users/renjx/Desktop/Get_Video
git add client/src-tauri/src/pipeline/ffmpeg.rs
git commit -m "ffmpeg: extract_audio_aac helper (64k mono AAC + faststart)"
```

---

### Task 10: library_sync.rs — upload audio sidecar + send audioKey

**Files:**
- Modify: `Get_Video/client/src-tauri/src/commands/library_sync.rs`

- [ ] **Step 1: Inside upload_video, after the successful PUT, extract + upload the audio sidecar**

In `Get_Video/client/src-tauri/src/commands/library_sync.rs` find the current `upload_video` fn (around line 326). At the END of the function, BEFORE the final `Ok(Some(uu.video_key))` return, hoist the return into a tuple so we can also return the audio key. Refactor:

  1. Change the function signature return type from `Result<Option<String>, String>` to `Result<Option<UploadedKeys>, String>`.
  2. Define a small struct at module scope (near the top of the file):

```rust
struct UploadedKeys {
    video_key: String,
    audio_key: Option<String>, // None when audio extract/upload best-effort failed
}
```

  3. Replace the final `Ok(Some(uu.video_key))` with audio extraction + upload + return:

```rust
// Video PUT succeeded — now extract + upload the audio sidecar.
// Best-effort: if any audio step fails, log + return without audio_key
// (iOS will fall back to the video URL for practice).
let audio_m4a = std::path::Path::new(video_dir).join("audio.m4a");
let audio_key = (async {
    if let Err(e) = crate::pipeline::ffmpeg::extract_audio_aac(app, &mobile, &audio_m4a, id).await {
        eprintln!("[upload_video] {id}: extract_audio_aac failed: {e}");
        return None;
    }
    let audio_bytes = match std::fs::read(&audio_m4a) {
        Ok(b) => b,
        Err(e) => { eprintln!("[upload_video] {id}: audio.m4a read failed: {e}"); return None; }
    };
    // Request a presigned PUT for the audio sidecar.
    let aclient = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(NET_TIMEOUT_SECS))
        .build()
    { Ok(c) => c, Err(_) => return None };
    let aresp = match aclient
        .post(format!("{API_BASE}/upload-url"))
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {token}"))
        .body(serde_json::json!({
            "id": id, "kind": "audio", "contentType": "audio/mp4",
            "contentLength": audio_bytes.len() as i64,
        }).to_string())
        .send().await
    { Ok(r) => r, Err(e) => { eprintln!("[upload_video] {id}: audio /upload-url failed: {e}"); return None; } };
    let aresp = match aresp.error_for_status() {
        Ok(r) => r,
        Err(e) => { eprintln!("[upload_video] {id}: audio /upload-url HTTP error: {e}"); return None; }
    };
    #[derive(serde::Deserialize)]
    struct AudioUploadUrl { #[serde(rename = "putUrl")] put_url: String, #[serde(rename = "audioKey")] audio_key: String }
    let auu: AudioUploadUrl = match aresp.text().await.ok().and_then(|t| serde_json::from_str(&t).ok()) {
        Some(v) => v,
        None => { eprintln!("[upload_video] {id}: audio /upload-url parse failed"); return None; }
    };
    // PUT the audio file. Small file → 60s timeout is more than enough.
    let put_client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build() { Ok(c) => c, Err(_) => return None };
    let put_resp = match put_client
        .put(&auu.put_url)
        .header("content-type", "audio/mp4")
        .body(audio_bytes)
        .send().await
    { Ok(r) => r, Err(e) => { eprintln!("[upload_video] {id}: OSS audio PUT failed: {e}"); return None; } };
    if !put_resp.status().is_success() {
        eprintln!("[upload_video] {id}: OSS audio PUT rejected: HTTP {}", put_resp.status());
        return None;
    }
    let _ = std::fs::remove_file(&audio_m4a);
    eprintln!("[upload_video] {id}: audio upload OK, key={}", auu.audio_key);
    Some(auu.audio_key)
}).await;

eprintln!("[upload_video] {id}: OSS upload OK ({size_mb} MB), key={}", uu.video_key);
Ok(Some(UploadedKeys { video_key: uu.video_key, audio_key }))
```

- [ ] **Step 2: Update library_sync_to_cloud to unpack the tuple + send audioKey**

In the same file find `let video_key: Option<String> = upload_video(...)` (around line 153). Replace with:

```rust
let uploaded: Option<UploadedKeys> = upload_video(
    &app, video_dir, &id, &auth_state.session_token, entry.duration_sec, limits_for_upload,
).await?;
let video_key: Option<String> = uploaded.as_ref().map(|u| u.video_key.clone());
let audio_key: Option<String> = uploaded.as_ref().and_then(|u| u.audio_key.clone());
```

Then in the `serde_json::json!({...})` body for the `/sync` POST a few lines later, add an `audioKey` field next to the existing `videoKey`:

```rust
let body = serde_json::json!({
    "id": entry.id,
    "youtubeId": youtube_id,
    "sourceUrl": source_url,
    "title": entry.title,
    "durationSec": entry.duration_sec as i64,
    "thumbUrl": if is_youtube {
        serde_json::Value::String(format!("https://i.ytimg.com/vi/{youtube_id}/mqdefault.jpg"))
    } else {
        serde_json::Value::Null
    },
    "transcriptSrt": transcript_text,
    "analysisJson": analysis_json,
    "thumbData": thumb_b64,
    "videoKey": video_key,
    "audioKey": audio_key,
});
```

- [ ] **Step 3: Compile-check**

Run: `cd C:/Users/renjx/Desktop/Get_Video/client/src-tauri && cargo check --message-format=short 2>&1 | grep -E "error|^warning: unused" | head -20`
Expected: no errors.

- [ ] **Step 4: Commit + push**

```bash
cd C:/Users/renjx/Desktop/Get_Video
git add client/src-tauri/src/commands/library_sync.rs
git commit -m "library_sync: upload audio sidecar after video PUT; send audioKey to /sync"
git push origin main
```

---

## Phase C — iOS (whatsub-mobile)

### Task 11: DTOs.swift — audioUrl optional field

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Networking/DTOs.swift`

- [ ] **Step 1: Add audioUrl to LibraryEntryDetail**

In `whatsub-mobile/whatsub-mobile/Networking/DTOs.swift` find the `struct LibraryEntryDetail: Decodable { ... }`. After the existing `let videoUrl: String?` line add:

```swift
/// Signed CDN URL for the audio-only .m4a sidecar (uploaded by desktop sync
/// since 2026-05-29). When non-nil, CueAudioPlayer prefers it over videoUrl
/// for practice — fetches ~3-5% of the bytes per cue. Nil for entries
/// synced before the sidecar feature; iOS falls back to videoUrl.
let audioUrl: String?
```

- [ ] **Step 2: Add audioUrl to LibraryListItem (same pattern)**

In the same file find `struct LibraryListItem: Decodable, Identifiable { ... }`. Add right after its `videoUrl`:

```swift
let audioUrl: String?
```

- [ ] **Step 3: Verify no other LibraryEntryDetail consumer breaks on the new optional**

Run: `grep -rn "LibraryEntryDetail(" C:/Users/renjx/Desktop/whatsub-mobile/whatsub-mobile --include='*.swift' | head -5`
Expected: only initializers via JSON decoding (no positional inits). Optional fields don't break Decodable consumers. No edits needed.

- [ ] **Step 4: Commit (LOCAL — per the standing rule, iOS commits without a code change shouldn't push to avoid burning a TestFlight cert slot; this commit DOES have a behavior path but the actual feature won't surface until later tasks land. Hold push.)**

```bash
cd C:/Users/renjx/Desktop/whatsub-mobile
git add whatsub-mobile/Networking/DTOs.swift
git commit -m "dto: add LibraryEntry{Detail,ListItem}.audioUrl (optional, backward-compat)"
```

---

### Task 12: CueAudioPlayer.swift — prefer audioURL when present

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Practice/CueAudioPlayer.swift`

- [ ] **Step 1: Extend the constructor to accept audioURL preferentially**

In `whatsub-mobile/whatsub-mobile/Practice/CueAudioPlayer.swift` find the current `init(sharedPlayer: AVPlayer? = nil, videoURL: URL? = nil)`. Replace with a version that takes `audioURL: URL?` as the first preference. The decision tree:

1. If `audioURL != nil`: build a dedicated AVPlayer for the small .m4a (no buffer sharing — file is small enough that a fresh AVPlayer is fast). Still snapshot+pause+restore `mainPlayer` if provided so the main video pauses during practice.
2. Else if `mainPlayer != nil`: existing shared-player path (audio comes from the same MP4 as the video, scrubbing the shared player).
3. Else if `videoURL != nil`: standalone player from URL (legacy fallback).
4. Else: dummy player.

Concrete shape (replaces the current init):

```swift
init(audioURL: URL? = nil, mainPlayer: AVPlayer? = nil, fallbackVideoURL: URL? = nil) {
    // Always snapshot + pause the main video player if provided — we want
    // practice to not have audio overlap with whatever was playing in the
    // detail view, regardless of which player we use for cue playback.
    if let main = mainPlayer {
        self.mainPlayer = main
        self.savedMainState = SavedSharedState(
            time: main.currentTime(),
            rate: main.rate,
            forwardEndTime: main.currentItem?.forwardPlaybackEndTime ?? .invalid,
            autoWaitsToMinimizeStalling: main.automaticallyWaitsToMinimizeStalling
        )
        main.pause()
    } else {
        self.mainPlayer = nil
        self.savedMainState = nil
    }
    // Pick the player we'll actually drive for cue playback.
    if let url = audioURL {
        let item = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: item)
        self.ownsPlayer = true
    } else if let main = mainPlayer {
        self.player = main
        self.ownsPlayer = false
    } else if let url = fallbackVideoURL {
        let item = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: item)
        self.ownsPlayer = true
    } else {
        self.player = AVPlayer()
        self.ownsPlayer = true
    }
    // ... (existing setActive / autoWaits=true / KVO observer / readiness probe code stays)
}
```

Also rename the existing private `private let savedState: SavedSharedState?` to `private let savedMainState: SavedSharedState?` and add `private let mainPlayer: AVPlayer?` + `private let ownsPlayer: Bool` properties at the top of the class.

- [ ] **Step 2: Update deinit to use the renamed savedMainState + only restore mainPlayer (not self.player when shared)**

Replace the existing `deinit` block with:

```swift
deinit {
    if let obs = timeObserver { player.removeTimeObserver(obs) }
    // Restore main video player state if we touched it
    if let main = mainPlayer, let saved = savedMainState {
        main.pause()
        main.automaticallyWaitsToMinimizeStalling = saved.autoWaitsToMinimizeStalling
        main.currentItem?.forwardPlaybackEndTime =
            saved.forwardEndTime.isValid ? saved.forwardEndTime : .positiveInfinity
        main.seek(to: saved.time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    // If our cue player is OWN (audio sidecar or standalone fallback), pause it.
    // (Shared case: main player == player, already paused above.)
    if ownsPlayer { player.pause() }
}
```

- [ ] **Step 3: Compile-check via inspection — Windows can't compile Swift; rely on CI**

Read the file end-to-end (or `Read` tool on the full file) and verify:
- Two new private properties declared: `mainPlayer: AVPlayer?` + `ownsPlayer: Bool`
- `savedState` renamed to `savedMainState` everywhere it's referenced (init + deinit)
- The init signature `init(audioURL:mainPlayer:fallbackVideoURL:)` exists
- `play()` / `stop()` / `preload()` methods unchanged — they all operate on `self.player` which is set up correctly by the init regardless of source

- [ ] **Step 4: Commit (LOCAL — still no push)**

```bash
cd C:/Users/renjx/Desktop/whatsub-mobile
git add whatsub-mobile/Practice/CueAudioPlayer.swift
git commit -m "CueAudioPlayer: prefer audioURL (m4a sidecar) over shared video player"
```

---

### Task 13: ShadowSheet.swift — thread audioURL through

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Practice/ShadowSheet.swift`

- [ ] **Step 1: Add audioURL param + pass to CueAudioPlayer**

In `whatsub-mobile/whatsub-mobile/Practice/ShadowSheet.swift` find the `init(cue:sharedPlayer:videoURL:)`. Add `audioURL: URL?` as the third param + update the CueAudioPlayer call:

```swift
init(cue: Cue, sharedPlayer: AVPlayer?, audioURL: URL?, videoURL: URL?) {
    self.cue = cue
    self.videoURL = videoURL
    // Prefer the audio sidecar (small .m4a, ~3-5% of the MP4) when the
    // backend provides it; fall back to the shared video player; final
    // fallback to a standalone URL-built player.
    _audio = StateObject(wrappedValue: CueAudioPlayer(
        audioURL: audioURL,
        mainPlayer: sharedPlayer,
        fallbackVideoURL: videoURL
    ))
}
```

- [ ] **Step 2: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-mobile
git add whatsub-mobile/Practice/ShadowSheet.swift
git commit -m "ShadowSheet: accept audioURL + prefer it via CueAudioPlayer"
```

---

### Task 14: ClozeSheet.swift — same pattern

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Practice/ClozeSheet.swift`

- [ ] **Step 1: Add audioURL param + update CueAudioPlayer call**

In `whatsub-mobile/whatsub-mobile/Practice/ClozeSheet.swift` find `init(cue:allCues:sharedPlayer:videoURL:)`. Add `audioURL: URL?` and route it through:

```swift
init(cue: Cue, allCues: [Cue], sharedPlayer: AVPlayer?, audioURL: URL?, videoURL: URL?) {
    self.allCues = allCues
    self.videoURL = videoURL
    _currentCue = State(initialValue: cue)
    _audio = StateObject(wrappedValue: CueAudioPlayer(
        audioURL: audioURL,
        mainPlayer: sharedPlayer,
        fallbackVideoURL: videoURL
    ))
}
```

- [ ] **Step 2: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-mobile
git add whatsub-mobile/Practice/ClozeSheet.swift
git commit -m "ClozeSheet: accept audioURL + prefer it via CueAudioPlayer"
```

---

### Task 15: LibraryDetailView.swift — compute ossAudioURL + wire to both sheets

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Library/LibraryDetailView.swift`

- [ ] **Step 1: Add an ossAudioURL computed property next to ossVideoURL**

Find the existing `private var ossVideoURL: URL?` near the top of the view (around line 34). Add right after it:

```swift
/// Signed CDN URL for the audio-only .m4a sidecar (since 2026-05-29 desktop
/// sync). When present, practice sheets use this instead of the full MP4 —
/// ~30× less bandwidth per cue. Nil for older entries that were synced
/// before the sidecar feature; practice falls back to the video URL.
private var ossAudioURL: URL? {
    guard let s = vm.entry?.audioUrl else { return nil }
    return URL(string: s)
}
```

- [ ] **Step 2: Update the ShadowSheet sheet call to pass audioURL**

Find the existing `.sheet(item: $shadowCue) { cue in ShadowSheet(cue: cue, sharedPlayer: avPlayer, videoURL: ossVideoURL) }`. Replace with:

```swift
.sheet(item: $shadowCue) { cue in
    ShadowSheet(
        cue: cue,
        sharedPlayer: avPlayer,
        audioURL: ossAudioURL,
        videoURL: ossVideoURL
    )
}
```

- [ ] **Step 3: Update the ClozeSheet sheet call to pass audioURL**

Find the existing `.sheet(item: $clozeCue) { cue in ClozeSheet(cue: cue, allCues: ..., sharedPlayer: avPlayer, videoURL: ossVideoURL) }`. Replace with:

```swift
.sheet(item: $clozeCue) { cue in
    ClozeSheet(
        cue: cue,
        allCues: vm.entry?.analysisJson.subtitles ?? [],
        sharedPlayer: avPlayer,
        audioURL: ossAudioURL,
        videoURL: ossVideoURL
    )
}
```

- [ ] **Step 4: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-mobile
git add whatsub-mobile/Library/LibraryDetailView.swift
git commit -m "LibraryDetailView: compute ossAudioURL and pass to practice sheets"
```

---

### Task 16: Push iOS to TestFlight + verify

**Files:** (no code changes)

- [ ] **Step 1: Push the iOS commits**

```bash
cd C:/Users/renjx/Desktop/whatsub-mobile
git push origin main
```

This triggers `testflight.yml`. Burns one Apple Distribution cert slot.

- [ ] **Step 2: Identify the new TestFlight run**

```bash
gh run list --repo rjxznb/whatsub-mobile --workflow=testflight.yml --limit 1 --json databaseId,headSha,displayTitle
```

Expected: a run whose `headSha` matches the latest local commit + `displayTitle` is the most recent commit's subject (e.g., the LibraryDetailView one).

- [ ] **Step 3: Watch the run to completion**

```bash
gh run watch <databaseId> --repo rjxznb/whatsub-mobile --exit-status
```

Expected: `success`. ~10 min.

- [ ] **Step 4: Manual on-device test plan (after build lands)**

In the LibraryDetailView of a freshly-synced video (re-sync any video from the desktop after the desktop push lands to populate audio_key):

  1. **First listen (cold)** — long-press a cue → 跟读练习 → wait while reading the cue text → tap 听原文. Audio should come out within ~500ms (download is now ~40 KB instead of ~1.2 MB).
  2. **Subsequent cues** — long-press another cue → 跟读 → tap 听原文. Should be similarly fast (Range requests against the same small .m4a; CDN cache may already have it).
  3. **Backward compat** — open an OLD video (synced before today's desktop push lands). Long-press cue → 跟读 → tap 听原文. Should still work (audioUrl is nil → fallback to shared main player → existing behavior).
  4. **Main video** — verify the main video player position is preserved across opening + closing a practice sheet (deinit's savedMainState restore).

---

## Out of scope (call out for follow-up plans, do NOT do in this plan)

- **Backfill existing entries** with audio sidecars. Approach when needed: admin script that iterates `WHERE audio_key IS NULL` rows, fetches the OSS video object, extracts audio server-side via a small worker, uploads + UPDATEs the row. Until that script exists, existing entries fall back to the video URL (slower but works).
- **Per-user audio storage limit** in the libraryLimits tier (currently size limit applies only to video; audio sidecars add a few MB per video which is rounding error vs the 500 MB video cap, but if it ever matters add `maxAudioBytes` to LibraryLimits).
- **Variable bitrate audio** — current plan is a single 64k mono encoding; HLS multi-bitrate would be option B from the prior discussion and was deferred.
- **Desktop standalone re-extract audio command** so users can backfill ONE video without a full re-sync (just `extract_audio_aac` + upload + db update). Useful but not required for the feature to ship.

---

## Self-review

**Spec coverage:**
- ✅ Desktop extracts .m4a + uploads (Tasks 9-10)
- ✅ Backend stores audio_key + emits audioUrl (Tasks 1-7)
- ✅ iOS prefers audioURL in practice (Tasks 11-15)
- ✅ Backward compat: old entries (no audio_key) fall back to video player path (Tasks 12 + 15 logic)
- ✅ DELETE cleans up both objects (Task 5)
- ✅ /upload-url supports kind=audio (Task 6)

**Type consistency:**
- `audioKey` (lowercase camelCase) used in both backend (TS) and desktop (Rust serde rename) and is consistent across all task code blocks
- `audioUrl` (returned by backend) → `audioURL: URL?` (iOS) consistent
- `LibraryEntryDetail.audioUrl` field (Task 11) is what `LibraryDetailView.ossAudioURL` (Task 15) reads — match ✓
- `CueAudioPlayer(audioURL:mainPlayer:fallbackVideoURL:)` (Task 12) is the same signature called from both sheets in Tasks 13/14 ✓
- `UploadedKeys { video_key, audio_key }` struct in desktop (Task 10) only used inside `library_sync.rs` — no cross-module surface ✓

**Placeholders:** none. Every code step has complete code; every command step has the exact command.

**Ordering:** Backend deploys BEFORE desktop pushes (so desktop's audioKey in /sync is accepted, not silently ignored). iOS can push at any time after backend is deployed (audioUrl will be null until desktop re-syncs an entry; iOS handles null gracefully).
