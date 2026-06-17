# Thumbnail Sync (封面根治) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** Sync the desktop's locally-extracted video thumbnail (downscaled) to the backend so iOS shows covers from a China-reachable URL (`whatsub.eversay.cc`) instead of the GFW-blocked Google CDN (`i.ytimg.com`). Result: Library list covers load WITHOUT a VPN.

**Architecture:** Desktop downscales `thumb.jpg` → 320px-wide JPEG via the bundled ffmpeg sidecar, base64-encodes it, sends as `thumbData` in `POST /api/library/sync`. Backend stores it in a new `thumb_data TEXT` column and serves it at a new **unauth** `GET /api/library/thumb/:id` (it's a YouTube video frame = public content; unauth keeps iOS `AsyncImage` simple). The list/entry `thumbUrl` points to the backend endpoint when a thumb exists, else falls back to the existing `i.ytimg.com` URL. **iOS needs NO changes** — it already consumes `thumbUrl` from the API.

**Tech Stack:** Hono + node-postgres + pg-mem (backend) · Rust + ffmpeg sidecar + base64 crate (desktop). iOS untouched.

**Repos:** `whatsub-license` (backend) + `Get_Video/client` (desktop). Plan 3 (desktop cloud sync) is now merged to main, so `library_sync.rs` is on main.

**Prereq done:** Plan 3 merged to main (desktop `library_sync.rs` + backend `/api/library/*` live).

---

## File Structure

**Backend (`whatsub-license`):**
| File | Change |
|---|---|
| `schema.sql` | + `thumb_data TEXT` column on library_entries |
| `src/lib/types.ts` | + `thumbData?` on SyncLibraryEntryInput |
| `src/lib/db.ts` | upsertLibraryEntry stores thumb_data; + `getLibraryThumb(id)`; list/entry compute thumbUrl |
| `src/routes/library.ts` | per-route auth (not blanket); POST /sync accepts thumbData; + unauth GET /thumb/:id |
| `tests/library-routes.test.ts` | + thumb tests |

**Desktop (`Get_Video/client`):**
| File | Change |
|---|---|
| `src-tauri/src/pipeline/ffmpeg.rs` | + `downscale_jpeg(app, src, dst, width)` helper |
| `src-tauri/src/commands/library_sync.rs` | downscale thumb + base64 + add thumbData to POST |
| `src-tauri/Cargo.toml` | + `base64` dep if absent |

**iOS:** none.

---

## Pre-flight

```bash
cd /c/Users/renjx/Desktop/whatsub-license
git checkout main && git pull
git checkout -b feat/thumbnail-sync
pnpm install && pnpm typecheck && pnpm test --run 2>&1 | tail -3
```
Expected: baseline green (307 tests).

---

### Task 1: Schema — thumb_data column

**Files:** Modify `schema.sql`

- [ ] **Step 1:** In the `library_entries` CREATE TABLE, the column list is fixed once created, so add an idempotent ALTER after the table definition (matches the repo's existing `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` pattern). After the `library_entries` table + its indexes, add:

```sql
-- Thumbnail bytes (base64-encoded JPEG, ~15-20 KB downscaled to 320px wide)
-- synced from the desktop's local ffmpeg-extracted thumb.jpg. Lets iOS load
-- covers from whatsub.eversay.cc (China-reachable) instead of the GFW-blocked
-- i.ytimg.com Google CDN. Nullable: entries synced before this feature, or
-- where the desktop couldn't read the thumb, fall back to the i.ytimg URL.
ALTER TABLE library_entries ADD COLUMN IF NOT EXISTS thumb_data TEXT;
```

- [ ] **Step 2:** Verify pg-mem parses it:
```bash
cd /c/Users/renjx/Desktop/whatsub-license
node -e "import('pg-mem').then(({newDb})=>{const m=newDb();m.public.none(require('fs').readFileSync('schema.sql','utf-8'));console.log('OK');})"
```
- [ ] **Step 3:** Commit:
```bash
git add schema.sql && git commit -m "feat(library/thumb): thumb_data column"
```

---

### Task 2: types + db — store thumbData + getLibraryThumb + thumbUrl logic

**Files:** Modify `src/lib/types.ts`, `src/lib/db.ts`

- [ ] **Step 1:** In `types.ts`, add `thumbData?: string` to `SyncLibraryEntryInput`:
```typescript
// inside SyncLibraryEntryInput, after thumbUrl?:
  thumbData?: string;   // base64 JPEG (downscaled). Stored in thumb_data column.
```

- [ ] **Step 2:** In `db.ts` `upsertLibraryEntry`, add `thumb_data` to the INSERT + ON CONFLICT UPDATE. Change the SQL + params:
  - Add `thumb_data` to the column list + a `$11` value `input.thumbData ?? null`
  - In `ON CONFLICT DO UPDATE SET`, add `thumb_data = EXCLUDED.thumb_data`
  - Bump the `storage_location` literal position accordingly (it's currently hardcoded `'inline'`; keep it, just add thumb_data as a new bound param). Read the current method + adjust param numbering carefully.

- [ ] **Step 3:** Add a `getLibraryThumb` method to `db.ts`:
```typescript
  /** Fetch just the base64 thumbnail for an entry (any owner — the thumb
   *  endpoint is public). Returns null if no thumb stored. */
  async getLibraryThumb(id: string): Promise<string | null> {
    const res = await this.pool.query<{ thumb_data: string | null }>(
      `SELECT thumb_data FROM library_entries WHERE id = $1 LIMIT 1`,
      [id],
    );
    return res.rows[0]?.thumb_data ?? null;
  }
```

- [ ] **Step 4:** Update `listLibraryEntriesForOwner` + `getLibraryEntry` so `thumbUrl` points to the backend thumb endpoint WHEN a thumb exists, else the existing value. Approach: SELECT a `has_thumb` boolean (`thumb_data IS NOT NULL`) and in the JS mapping set:
```typescript
thumbUrl: hasThumb
  ? `https://whatsub.eversay.cc/api/library/thumb/${r.id}`
  : r.thumb_url,
```
For `listLibraryEntriesForOwner`: add `thumb_data IS NOT NULL AS has_thumb` to the SELECT, map as above.
For `getLibraryEntry`: same (add has_thumb to SELECT, override thumbUrl in the returned row). Note `getLibraryEntry` returns `LibraryEntryRow` which has `thumbUrl`; set it to the backend URL when has_thumb.

(Don't SELECT the full `thumb_data` in list/entry — only the `IS NOT NULL` boolean — to keep those responses light.)

- [ ] **Step 5:** typecheck:
```bash
pnpm typecheck
```
- [ ] **Step 6:** Commit:
```bash
git add src/lib/types.ts src/lib/db.ts && git commit -m "feat(library/thumb): store thumb_data + getLibraryThumb + backend thumbUrl"
```

---

### Task 3: routes — per-route auth + accept thumbData + unauth GET /thumb/:id (TDD)

**Files:** Modify `tests/library-routes.test.ts`, `src/routes/library.ts`

- [ ] **Step 1: Failing tests** — append to `tests/library-routes.test.ts`:

```typescript
describe('thumbnail sync + serve', () => {
  // 1x1 transparent JPEG-ish base64 (any base64 string works for store/serve roundtrip).
  const TINY_B64 = Buffer.from('fake-jpeg-bytes').toString('base64');

  it('POST /sync stores thumbData; GET /thumb/:id serves it unauth', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    const res = await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'tvid', thumbData: TINY_B64 }),
    });
    expect(res.status).toBe(200);

    // thumb endpoint requires NO auth
    const thumbRes = await rig.app.request('/api/library/thumb/tvid');
    expect(thumbRes.status).toBe(200);
    expect(thumbRes.headers.get('content-type')).toContain('image/jpeg');
    const buf = Buffer.from(await thumbRes.arrayBuffer());
    expect(buf.toString()).toBe('fake-jpeg-bytes');
  });

  it('GET /thumb/:id 404 when no thumb', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'nothumb' }),  // no thumbData
    });
    const r = await rig.app.request('/api/library/thumb/nothumb');
    expect(r.status).toBe(404);
  });

  it('list thumbUrl points to backend when thumb present, i.ytimg when not', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    await rig.app.request('/api/library/sync', {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'withthumb', thumbData: TINY_B64 }),
    });
    await rig.app.request('/api/library/sync', {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'nothumb2', thumbUrl: 'https://i.ytimg.com/x.jpg' }),
    });
    const res = await rig.app.request('/api/library/list', { headers: { authorization: `Bearer ${token}` } });
    const body = (await res.json()) as { entries: Array<{ id: string; thumbUrl: string | null }> };
    const withThumb = body.entries.find((e) => e.id === 'withthumb')!;
    const noThumb = body.entries.find((e) => e.id === 'nothumb2')!;
    expect(withThumb.thumbUrl).toBe('https://whatsub.eversay.cc/api/library/thumb/withthumb');
    expect(noThumb.thumbUrl).toBe('https://i.ytimg.com/x.jpg');
  });
});
```

- [ ] **Step 2: Run, verify RED** (thumb route 404/missing):
```bash
pnpm test tests/library-routes.test.ts --run 2>&1 | tail -15
```

- [ ] **Step 3: Restructure `src/routes/library.ts`** — replace blanket auth with per-route auth + add thumb route. New file body:

```typescript
import { Hono } from 'hono';
import type { Database } from '../lib/db.js';
import { requireSession } from '../lib/auth.js';

export function libraryRoute(db: Database) {
  const app = new Hono();

  // Public (unauth): thumbnail bytes. It's a YouTube video frame (public
  // content) + AsyncImage on iOS can't easily attach a bearer header. Served
  // by entry id; no cross-user data is exposed (just the cover image).
  app.get('/thumb/:id', async (c) => {
    const id = c.req.param('id');
    if (!id) return c.json({ error: 'invalid_input' }, 400);
    const b64 = await db.getLibraryThumb(id);
    if (!b64) return c.json({ error: 'not_found' }, 404);
    const bytes = Buffer.from(b64, 'base64');
    return c.body(bytes, 200, {
      'Content-Type': 'image/jpeg',
      'Cache-Control': 'public, max-age=86400',
    });
  });

  // Everything else is session-gated (per-route, so /thumb above stays public).
  app.post('/sync', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    let body: Record<string, unknown>;
    try {
      body = (await c.req.json()) as Record<string, unknown>;
    } catch {
      return c.json({ error: 'invalid_json' }, 400);
    }
    const id = typeof body.id === 'string' ? body.id.trim() : '';
    const youtubeId = typeof body.youtubeId === 'string' ? body.youtubeId.trim() : '';
    const sourceUrl = typeof body.sourceUrl === 'string' ? body.sourceUrl.trim() : '';
    const title = typeof body.title === 'string' ? body.title.trim() : '';
    const transcriptSrt = typeof body.transcriptSrt === 'string' ? body.transcriptSrt : '';
    const analysisJson = body.analysisJson;
    if (!id || !youtubeId || !sourceUrl || !title || !transcriptSrt || analysisJson == null) {
      return c.json({ error: 'invalid_input' }, 400);
    }
    const durationSec =
      typeof body.durationSec === 'number' && Number.isFinite(body.durationSec)
        ? Math.floor(body.durationSec)
        : undefined;
    const thumbUrl = typeof body.thumbUrl === 'string' ? body.thumbUrl : undefined;
    const thumbData = typeof body.thumbData === 'string' ? body.thumbData : undefined;
    await db.upsertLibraryEntry({
      id, ownerEmail: email, youtubeId, sourceUrl, title,
      durationSec, thumbUrl, transcriptSrt, analysisJson, thumbData,
      now: Date.now(),
    });
    return c.json({ ok: true });
  });

  app.delete('/sync/:id', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    const id = c.req.param('id');
    if (!id) return c.json({ error: 'invalid_input' }, 400);
    const removed = await db.deleteLibraryEntry(id, email);
    if (!removed) return c.json({ error: 'not_found' }, 404);
    return c.json({ ok: true });
  });

  app.get('/list', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    const entries = await db.listLibraryEntriesForOwner(email);
    return c.json({ entries });
  });

  app.get('/entry/:id', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    const id = c.req.param('id');
    if (!id) return c.json({ error: 'invalid_input' }, 400);
    const entry = await db.getLibraryEntry(id, email);
    if (!entry) return c.json({ error: 'not_found' }, 404);
    return c.json(entry);
  });

  return app;
}
```

(Verify the existing handler bodies match — copy them verbatim from the current file; only the auth placement + thumbData + thumb route are new.)

- [ ] **Step 4: Run, verify GREEN:**
```bash
pnpm test tests/library-routes.test.ts --run 2>&1 | tail -10
pnpm typecheck && pnpm test --run 2>&1 | tail -4
```
Expected: all library-routes tests pass (existing 16 + 3 new); full suite green.

- [ ] **Step 5: Commit:**
```bash
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "feat(library/thumb): per-route auth + accept thumbData + unauth GET /thumb/:id"
```

---

### Task 4: Backend deploy (schema + container) — PAUSE for user authorization

**STOP. Get user authorization before prod deploy (container restart ~3-5s).**

- [ ] **Step 1:** Merge to main:
```bash
git checkout main && git merge --no-ff feat/thumbnail-sync -m "feat(library/thumb): backend thumbnail sync + serve"
git push origin main && git branch -d feat/thumbnail-sync
```
- [ ] **Step 2:** Apply schema (idempotent ALTER):
```bash
scp -i ~/.ssh/id_ed25519 schema.sql root@47.93.87.206:/tmp/schema-thumb.sql
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "docker exec -i enghub-postgres-1 psql -U whatsub_license_user -d whatsub_license < /tmp/schema-thumb.sql && docker exec -i enghub-postgres-1 psql -U whatsub_license_user -d whatsub_license -c '\\d library_entries' | grep thumb_data"
```
Expected: `thumb_data | text` shown.
- [ ] **Step 3:** Build + deploy:
```bash
docker buildx build --load -t whatsub-license:latest .
docker save whatsub-license:latest | gzip > /tmp/whatsub-license.tar.gz
scp -i ~/.ssh/id_ed25519 /tmp/whatsub-license.tar.gz root@47.93.87.206:/tmp/
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "docker load < /tmp/whatsub-license.tar.gz && cd /opt/whatsub && docker compose --env-file .env up -d --force-recreate whatsub-license && rm /tmp/whatsub-license.tar.gz && docker logs --tail 6 whatsub-license"
```
- [ ] **Step 4:** Smoke (thumb endpoint 404 for an entry without thumb — proves route is live + unauth):
```bash
curl -s -o /dev/null -w "thumb (no data yet) → HTTP %{http_code}\n" https://whatsub.eversay.cc/api/library/thumb/ECXAFUmdJkI
```
Expected: HTTP 404 (entry exists but no thumb_data yet — proves the endpoint works + is unauth). After the desktop re-syncs (Task 7), this becomes 200.

---

### Task 5: Desktop — ffmpeg downscale helper

**Files:** Modify `src-tauri/src/pipeline/ffmpeg.rs`

Work in `/c/Users/renjx/Desktop/Get_Video/client`, branch `feat/desktop-thumb-upload` off main.

- [ ] **Step 1:** Add a downscale helper after `extract_thumbnail` in `ffmpeg.rs`:
```rust
/// Downscale an existing image (e.g. thumb.jpg) to `width` px wide (height
/// auto, preserving aspect; -2 keeps it even for the encoder) as JPEG.
/// Used by library cloud-sync to ship a small (~15 KB) cover instead of the
/// full-res frame. Reuses the bundled ffmpeg sidecar — no new deps.
pub async fn downscale_jpeg(
    app: &AppHandle,
    src_path: &Path,
    out_path: &Path,
    width: u32,
    video_id: &str,
    cancel: Option<&CancellationToken>,
) -> AppResult<()> {
    let src = src_path.to_string_lossy().to_string();
    let out = out_path.to_string_lossy().to_string();
    let scale = format!("scale={width}:-2");
    let log = make_log_emitter(app, video_id);
    run_sidecar(
        app,
        "ffmpeg",
        &["-y", "-i", &src, "-vf", &scale, "-q:v", "5", &out],
        log,
        cancel,
    )
    .await?;
    Ok(())
}
```

- [ ] **Step 2:** `cargo build --quiet 2>&1 | tail -5` (in src-tauri). Expected: clean.
- [ ] **Step 3:** Commit:
```bash
cd /c/Users/renjx/Desktop/Get_Video/client
git add src-tauri/src/pipeline/ffmpeg.rs
git commit -m "feat(thumb): ffmpeg downscale_jpeg helper"
```

---

### Task 6: Desktop — library_sync uploads thumbData

**Files:** Modify `src-tauri/src/commands/library_sync.rs`, maybe `Cargo.toml`

- [ ] **Step 1:** In `library_sync_to_cloud`, after reading transcript + analysis and BEFORE building the POST body, downscale + base64 the thumb (best-effort — if it fails, sync without thumb):
```rust
    // Downscale the local thumb.jpg → small JPEG → base64 (best-effort; a
    // missing/failed thumb just means the entry falls back to the i.ytimg URL).
    let thumb_b64: Option<String> = {
        let thumb_src = std::path::Path::new(video_dir).join("thumb.jpg");
        let thumb_small = std::path::Path::new(video_dir).join("thumb_small.jpg");
        if thumb_src.exists() {
            match crate::pipeline::ffmpeg::downscale_jpeg(&app, &thumb_src, &thumb_small, 320, &id, None).await {
                Ok(()) => std::fs::read(&thumb_small).ok().map(|bytes| {
                    use base64::Engine;
                    base64::engine::general_purpose::STANDARD.encode(bytes)
                }),
                Err(_) => None,
            }
        } else {
            None
        }
    };
```
Then add `"thumbData": thumb_b64,` to the `serde_json::json!({...})` POST body (serde serializes `None` as `null`, which the backend treats as "no thumb").

- [ ] **Step 2:** Ensure `base64` crate is available:
```bash
cd /c/Users/renjx/Desktop/Get_Video/client/src-tauri
grep -q '^base64' Cargo.toml || cargo add base64
```
- [ ] **Step 3:** `cargo build --quiet 2>&1 | tail -5` — clean. `cargo test --quiet 2>&1 | tail -5` — green.
- [ ] **Step 4:** Commit:
```bash
cd /c/Users/renjx/Desktop/Get_Video/client
git add src-tauri/src/commands/library_sync.rs src-tauri/Cargo.toml src-tauri/Cargo.lock
git commit -m "feat(thumb): upload downscaled thumb in library_sync"
```

---

### Task 7: Manual verify + re-sync — PAUSE for user

**STOP. This requires the user's desktop (pnpm tauri dev) + their iPhone.**

- [ ] **Step 1:** User merges desktop branch to main (or runs from branch):
```bash
cd /c/Users/renjx/Desktop/Get_Video/client
git checkout main && git merge --no-ff feat/desktop-thumb-upload -m "feat(thumb): desktop uploads downscaled thumbnail" && git push origin main
```
- [ ] **Step 2:** User runs `pnpm tauri dev`, goes to Library, **re-syncs** the existing videos (click ☁️ → already-synced → re-sync) so they get thumb_data uploaded.
- [ ] **Step 3:** Verify backend now serves the thumb:
```bash
curl -s -o /dev/null -w "thumb → HTTP %{http_code}\n" https://whatsub.eversay.cc/api/library/thumb/ECXAFUmdJkI
```
Expected: HTTP 200 (after re-sync).
- [ ] **Step 4:** User on iPhone: Library tab → pull-to-refresh → **covers now load even without VPN** (thumbUrl points to whatsub.eversay.cc). Confirm.

---

## Done criteria

- Backend: `thumb_data` column live; `GET /api/library/thumb/:id` serves JPEG unauth; list/entry `thumbUrl` → backend when thumb present
- Desktop: library_sync downscales + uploads thumb on sync
- iOS (unchanged): Library covers load from whatsub.eversay.cc → visible WITHOUT VPN
- Existing entries fixed by re-syncing from desktop

## Notes
- iOS requires NO code change or rebuild — it already uses `thumbUrl` from the API.
- Video PLAYBACK still needs VPN (YouTube embed is Google) — only the COVER is fixed here.
- Storage: ~15-20 KB base64 per entry; negligible vs the ~90 KB analysis data already stored (see disk analysis: 16 GB free, ~150K entries headroom).
