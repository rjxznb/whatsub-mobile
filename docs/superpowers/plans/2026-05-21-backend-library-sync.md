# Backend library_entries + sync API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `library_entries` table + 4 HTTP endpoints to `whatsub-license` backend so desktop can push parsed YouTube library entries to the cloud and iOS can pull them.

**Architecture:** New Hono route file `src/routes/library.ts` mounted at `/api/library/*`. All 4 endpoints session-gated via existing `requireSession(db)` middleware (no license gate — library data is the user's own). Storage: a single Postgres table (TEXT/JSONB columns via TOAST, no OSS for v1). Partition by `owner_email` derived from session.

**Tech Stack:** Hono 4 · node-postgres 8.x · pg-mem 3.x (tests) · Vitest 1.x · TypeScript NodeNext.

**Working dir:** `C:\Users\renjx\Desktop\whatsub-license`. All file paths in this plan are relative to that.

---

## File Structure

| File | Responsibility |
|---|---|
| `schema.sql` (modify) | Append `CREATE TABLE library_entries` + 2 indexes |
| `src/lib/types.ts` (modify) | Add `LibraryEntryRow / LibraryEntryListItem / SyncLibraryEntryInput` |
| `src/lib/db.ts` (modify) | Add 4 methods: `upsertLibraryEntry / getLibraryEntry / listLibraryEntriesForOwner / deleteLibraryEntry` |
| `src/routes/library.ts` (create) | `libraryRoute(db)` Hono router exposing POST `/sync`, DELETE `/sync/:id`, GET `/list`, GET `/entry/:id` |
| `src/index.ts` (modify) | Register `app.route('/api/library', libraryRoute(db))` |
| `tests/library-db.test.ts` (create) | Unit tests for the 4 Database methods (pg-mem) |
| `tests/library-routes.test.ts` (create) | Integration tests for the 4 endpoints (Hono request testing + pg-mem) |

**Existing patterns to follow** (do NOT re-invent):
- Database class pattern: `src/lib/db.ts` — one method per query, types injected at construction
- Route pattern: `src/routes/corpus.ts` — `corpusRoute(db, deps?)` returns `new Hono()`
- Auth pattern: `src/lib/auth.ts::requireSession(db)` — sets `c.get('email')` + `c.get('hasActiveLicense')`
- Test rig: `tests/corpus-routes.test.ts` lines 21-52 — `makeApp()` + `insertSessionFor()` helpers

---

## Pre-flight (do once before Task 1)

- [ ] **Confirm working dir + git branch is clean**

```bash
cd /c/Users/renjx/Desktop/whatsub-license
git status                          # working tree clean
git checkout main && git pull       # latest main
git checkout -b feat/library-sync   # feature branch
pnpm install                        # ensure deps
pnpm test                           # baseline: all existing tests pass before we touch anything
pnpm typecheck                      # baseline: no TS errors
```

Expected: all tests green, no TS errors. **If any test fails on baseline, STOP and investigate before adding any code.**

---

### Task 1: Schema migration

**Files:**
- Modify: `schema.sql` — append new section at end

- [ ] **Step 1: Add table + indexes to schema.sql**

Append to `schema.sql` (end of file, after `admin_emails`):

```sql

-- Library entries synced from desktop to cloud (added 2026-05-21).
--
-- Desktop POSTs /api/library/sync with a parsed YouTube library entry
-- (transcript.srt + analysis.json + metadata). iOS GETs /list (lightweight)
-- and /entry/:id (full) to render LibraryView + LibraryDetailView.
--
-- v1 scope: YouTube source only. Non-YouTube entries can't be synced.
--
-- Storage decision: TEXT/JSONB inline in Postgres. TOAST handles big
-- fields transparently. `storage_location` field is a future hint for
-- OSS migration — always 'inline' today. See spec § 9 for the trigger
-- to switch to OSS hybrid (DB > 30 GB / single row > 1 MB / want CDN).
--
-- owner_email is the partition key. Derived from session at write time;
-- iOS pull paths filter by it. No cross-user access path exists.
CREATE TABLE IF NOT EXISTS library_entries (
    id                TEXT     PRIMARY KEY,        -- desktop's library video_id
    owner_email       TEXT     NOT NULL,
    youtube_id        TEXT     NOT NULL,            -- v1 only YouTube
    source_url        TEXT     NOT NULL,
    title             TEXT     NOT NULL,
    duration_sec      INTEGER,
    thumb_url         TEXT,                          -- https://i.ytimg.com/vi/{yt}/mqdefault.jpg
    transcript_srt    TEXT     NOT NULL,             -- ~10-50 KB
    analysis_json     JSONB    NOT NULL,             -- ~50-300 KB
    storage_location  TEXT     NOT NULL DEFAULT 'inline',  -- 'inline' | 'oss' (v2 reserved)
    synced_at         BIGINT   NOT NULL              -- unix ms
);

CREATE INDEX IF NOT EXISTS idx_library_owner
    ON library_entries (owner_email, synced_at DESC);
CREATE INDEX IF NOT EXISTS idx_library_owner_yt
    ON library_entries (owner_email, youtube_id);
```

- [ ] **Step 2: Verify SQL is syntactically valid**

```bash
cd /c/Users/renjx/Desktop/whatsub-license
node -e "import('pg-mem').then(({newDb})=>{const m=newDb();m.public.none(require('fs').readFileSync('schema.sql','utf-8'));console.log('OK');});"
```

Expected: prints `OK` (pg-mem accepted the full schema).

- [ ] **Step 3: Commit**

```bash
git add schema.sql
git commit -m "feat(library): add library_entries table for cloud sync"
```

---

### Task 2: Types

**Files:**
- Modify: `src/lib/types.ts` — append new types at end

- [ ] **Step 1: Add types**

Append to `src/lib/types.ts`:

```typescript

// ----- Library entries (cloud sync, added 2026-05-21) -------------------

/** Full library entry as stored in DB.
 *  camelCase for caller-facing shape; the raw pg row is snake_case and
 *  mapped in db.ts. analysisJson is JSONB; we expose it as the bilingual
 *  + highlights structure the desktop pipeline emits. */
export interface LibraryEntryRow {
  id: string;
  ownerEmail: string;
  youtubeId: string;
  sourceUrl: string;
  title: string;
  durationSec: number | null;
  thumbUrl: string | null;
  transcriptSrt: string;
  /** Raw analysis structure from desktop's analysis.json. The backend is
   *  oblivious to shape — it's a pass-through blob. iOS interprets. */
  analysisJson: unknown;
  storageLocation: 'inline' | 'oss';
  syncedAt: number;
}

/** Lightweight row for /list — no large fields (transcript / analysis).
 *  iOS calls /list first, then /entry/:id for the one the user taps. */
export interface LibraryEntryListItem {
  id: string;
  youtubeId: string;
  sourceUrl: string;
  title: string;
  durationSec: number | null;
  thumbUrl: string | null;
  syncedAt: number;
}

/** Input shape for Database#upsertLibraryEntry. ownerEmail derived from
 *  session by the route layer, not the desktop body. */
export interface SyncLibraryEntryInput {
  id: string;
  ownerEmail: string;
  youtubeId: string;
  sourceUrl: string;
  title: string;
  durationSec?: number;
  thumbUrl?: string;
  transcriptSrt: string;
  analysisJson: unknown;
  now: number;
}
```

- [ ] **Step 2: Typecheck**

```bash
pnpm typecheck
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/lib/types.ts
git commit -m "feat(library): add LibraryEntryRow + list item + input types"
```

---

### Task 3: Database method — upsertLibraryEntry (TDD)

**Files:**
- Create: `tests/library-db.test.ts`
- Modify: `src/lib/db.ts` — add method on `Database` class

- [ ] **Step 1: Write the failing test**

Create `tests/library-db.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import { newDb, type IMemoryDb } from 'pg-mem';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Database } from '../src/lib/db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

function makeDb(): { db: Database; mem: IMemoryDb } {
  const mem = newDb();
  const sql = readFileSync(join(__dirname, '..', 'schema.sql'), 'utf-8');
  mem.public.none(sql);
  const adapter = mem.adapters.createPg();
  return { db: new Database(new adapter.Pool()), mem };
}

const SAMPLE_ANALYSIS = {
  cues: [
    { startSec: 0, endSec: 2, en: 'Hello world.', zh: '你好世界。', highlights: [] },
  ],
  summary: '简单的问候。',
};

function sampleInput(over: Partial<Parameters<Database['upsertLibraryEntry']>[0]> = {}) {
  return {
    id: 'vid-abc123',
    ownerEmail: 'alice@example.com',
    youtubeId: 'abc123',
    sourceUrl: 'https://www.youtube.com/watch?v=abc123',
    title: 'Sample Video',
    durationSec: 120,
    thumbUrl: 'https://i.ytimg.com/vi/abc123/mqdefault.jpg',
    transcriptSrt: '1\n00:00:00,000 --> 00:00:02,000\nHello world.\n',
    analysisJson: SAMPLE_ANALYSIS,
    now: 1_700_000_000_000,
    ...over,
  };
}

describe('Database#upsertLibraryEntry', () => {
  it('inserts a new entry and returns nothing', async () => {
    const { db } = makeDb();
    await db.upsertLibraryEntry(sampleInput());
    const got = await db.getLibraryEntry('vid-abc123', 'alice@example.com');
    expect(got).toBeDefined();
    expect(got!.id).toBe('vid-abc123');
    expect(got!.ownerEmail).toBe('alice@example.com');
    expect(got!.title).toBe('Sample Video');
    expect(got!.transcriptSrt).toContain('Hello world');
    expect(got!.analysisJson).toEqual(SAMPLE_ANALYSIS);
    expect(got!.syncedAt).toBe(1_700_000_000_000);
    expect(got!.storageLocation).toBe('inline');
  });

  it('updates an existing entry (upsert semantics, bumps synced_at)', async () => {
    const { db } = makeDb();
    await db.upsertLibraryEntry(sampleInput());
    await db.upsertLibraryEntry(
      sampleInput({
        title: 'New Title',
        now: 1_700_000_005_000,
      }),
    );
    const got = await db.getLibraryEntry('vid-abc123', 'alice@example.com');
    expect(got!.title).toBe('New Title');
    expect(got!.syncedAt).toBe(1_700_000_005_000);
  });
});
```

- [ ] **Step 2: Run test, verify it fails**

```bash
pnpm test tests/library-db.test.ts
```

Expected: FAIL with `TypeError: db.upsertLibraryEntry is not a function` (or `db.getLibraryEntry`).

- [ ] **Step 3: Implement the methods on Database**

Add to `src/lib/db.ts` inside the `Database` class (before the closing `}` of the class):

```typescript
  // ----- Library entries (cloud sync, added 2026-05-21) -----------------

  async upsertLibraryEntry(input: SyncLibraryEntryInput): Promise<void> {
    await this.pool.query(
      `INSERT INTO library_entries
         (id, owner_email, youtube_id, source_url, title, duration_sec,
          thumb_url, transcript_srt, analysis_json, storage_location, synced_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'inline', $10)
       ON CONFLICT (id) DO UPDATE SET
         owner_email     = EXCLUDED.owner_email,
         youtube_id      = EXCLUDED.youtube_id,
         source_url      = EXCLUDED.source_url,
         title           = EXCLUDED.title,
         duration_sec    = EXCLUDED.duration_sec,
         thumb_url       = EXCLUDED.thumb_url,
         transcript_srt  = EXCLUDED.transcript_srt,
         analysis_json   = EXCLUDED.analysis_json,
         synced_at       = EXCLUDED.synced_at`,
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
      ],
    );
  }

  async getLibraryEntry(id: string, ownerEmail: string): Promise<LibraryEntryRow | undefined> {
    const res = await this.pool.query<{
      id: string;
      owner_email: string;
      youtube_id: string;
      source_url: string;
      title: string;
      duration_sec: number | null;
      thumb_url: string | null;
      transcript_srt: string;
      analysis_json: unknown;
      storage_location: string;
      synced_at: number;
    }>(
      `SELECT id, owner_email, youtube_id, source_url, title, duration_sec,
              thumb_url, transcript_srt, analysis_json, storage_location, synced_at
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
      thumbUrl: r.thumb_url,
      transcriptSrt: r.transcript_srt,
      analysisJson: r.analysis_json,
      storageLocation: (r.storage_location === 'oss' ? 'oss' : 'inline'),
      syncedAt: r.synced_at,
    };
  }
```

Also add the imports at the top of `db.ts` if not already there:

```typescript
// in the existing import block from './types.js'
import type {
  // ...existing imports...
  LibraryEntryRow,
  LibraryEntryListItem,
  SyncLibraryEntryInput,
} from './types.js';
```

- [ ] **Step 4: Run test, verify it passes**

```bash
pnpm test tests/library-db.test.ts
```

Expected: 2/2 pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/db.ts tests/library-db.test.ts
git commit -m "feat(library): db.upsertLibraryEntry + getLibraryEntry"
```

---

### Task 4: Database method — listLibraryEntriesForOwner (TDD)

**Files:**
- Modify: `tests/library-db.test.ts`
- Modify: `src/lib/db.ts`

- [ ] **Step 1: Add failing test**

Append to `tests/library-db.test.ts`:

```typescript
describe('Database#listLibraryEntriesForOwner', () => {
  it('returns lightweight rows for the given owner, newest synced_at first', async () => {
    const { db } = makeDb();
    await db.upsertLibraryEntry(sampleInput({ id: 'a', now: 1000 }));
    await db.upsertLibraryEntry(sampleInput({ id: 'b', now: 3000 }));
    await db.upsertLibraryEntry(sampleInput({ id: 'c', now: 2000 }));
    const rows = await db.listLibraryEntriesForOwner('alice@example.com');
    expect(rows.map((r) => r.id)).toEqual(['b', 'c', 'a']);
    // Lightweight: no transcript / analysis
    expect((rows[0] as unknown as Record<string, unknown>)['transcriptSrt']).toBeUndefined();
    expect((rows[0] as unknown as Record<string, unknown>)['analysisJson']).toBeUndefined();
  });

  it('does not return entries for other owners', async () => {
    const { db } = makeDb();
    await db.upsertLibraryEntry(sampleInput({ id: 'a', ownerEmail: 'alice@example.com' }));
    await db.upsertLibraryEntry(sampleInput({ id: 'b', ownerEmail: 'bob@example.com' }));
    const aliceRows = await db.listLibraryEntriesForOwner('alice@example.com');
    expect(aliceRows.map((r) => r.id)).toEqual(['a']);
  });

  it('returns empty array when owner has no entries', async () => {
    const { db } = makeDb();
    const rows = await db.listLibraryEntriesForOwner('nobody@example.com');
    expect(rows).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test, verify fail**

```bash
pnpm test tests/library-db.test.ts
```

Expected: 3 new tests FAIL with `db.listLibraryEntriesForOwner is not a function`.

- [ ] **Step 3: Implement method on Database**

Add to `src/lib/db.ts` (after `getLibraryEntry`):

```typescript
  async listLibraryEntriesForOwner(ownerEmail: string): Promise<LibraryEntryListItem[]> {
    const res = await this.pool.query<{
      id: string;
      youtube_id: string;
      source_url: string;
      title: string;
      duration_sec: number | null;
      thumb_url: string | null;
      synced_at: number;
    }>(
      `SELECT id, youtube_id, source_url, title, duration_sec, thumb_url, synced_at
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
      thumbUrl: r.thumb_url,
      syncedAt: r.synced_at,
    }));
  }
```

- [ ] **Step 4: Run test, verify pass**

```bash
pnpm test tests/library-db.test.ts
```

Expected: 5/5 total pass (2 prior + 3 new).

- [ ] **Step 5: Commit**

```bash
git add src/lib/db.ts tests/library-db.test.ts
git commit -m "feat(library): db.listLibraryEntriesForOwner"
```

---

### Task 5: Database method — deleteLibraryEntry (TDD)

**Files:**
- Modify: `tests/library-db.test.ts`
- Modify: `src/lib/db.ts`

- [ ] **Step 1: Add failing tests**

Append to `tests/library-db.test.ts`:

```typescript
describe('Database#deleteLibraryEntry', () => {
  it('removes a matching entry and returns true', async () => {
    const { db } = makeDb();
    await db.upsertLibraryEntry(sampleInput({ id: 'a' }));
    const removed = await db.deleteLibraryEntry('a', 'alice@example.com');
    expect(removed).toBe(true);
    const got = await db.getLibraryEntry('a', 'alice@example.com');
    expect(got).toBeUndefined();
  });

  it('returns false for non-existent id', async () => {
    const { db } = makeDb();
    const removed = await db.deleteLibraryEntry('nope', 'alice@example.com');
    expect(removed).toBe(false);
  });

  it('returns false when owner_email does not match (cross-user safety)', async () => {
    const { db } = makeDb();
    await db.upsertLibraryEntry(sampleInput({ id: 'a', ownerEmail: 'alice@example.com' }));
    const removed = await db.deleteLibraryEntry('a', 'bob@example.com');
    expect(removed).toBe(false);
    // Alice's entry still there
    const stillThere = await db.getLibraryEntry('a', 'alice@example.com');
    expect(stillThere).toBeDefined();
  });
});
```

- [ ] **Step 2: Run test, verify fail**

```bash
pnpm test tests/library-db.test.ts
```

Expected: 3 new tests FAIL with `db.deleteLibraryEntry is not a function`.

- [ ] **Step 3: Implement method**

Add to `src/lib/db.ts`:

```typescript
  async deleteLibraryEntry(id: string, ownerEmail: string): Promise<boolean> {
    const res = await this.pool.query(
      `DELETE FROM library_entries WHERE id = $1 AND owner_email = $2`,
      [id, ownerEmail],
    );
    return (res.rowCount ?? 0) > 0;
  }
```

- [ ] **Step 4: Run test, verify pass**

```bash
pnpm test tests/library-db.test.ts
```

Expected: 8/8 pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/db.ts tests/library-db.test.ts
git commit -m "feat(library): db.deleteLibraryEntry with owner-key safety"
```

---

### Task 6: Route file scaffold — `src/routes/library.ts` + wiring

**Files:**
- Create: `src/routes/library.ts`
- Modify: `src/index.ts` — register the new route

- [ ] **Step 1: Create scaffold (empty handlers that 501)**

Create `src/routes/library.ts`:

```typescript
import { Hono } from 'hono';
import type { Database } from '../lib/db.js';
import { requireSession } from '../lib/auth.js';

export function libraryRoute(db: Database) {
  const app = new Hono();
  app.use('*', requireSession(db));

  app.post('/sync', async (c) => c.json({ error: 'not_implemented' }, 501));
  app.delete('/sync/:id', async (c) => c.json({ error: 'not_implemented' }, 501));
  app.get('/list', async (c) => c.json({ error: 'not_implemented' }, 501));
  app.get('/entry/:id', async (c) => c.json({ error: 'not_implemented' }, 501));

  return app;
}
```

- [ ] **Step 2: Register in buildApp**

Modify `src/index.ts`. Add the import near the other route imports (line ~18):

```typescript
import { libraryRoute } from './routes/library.js';
```

In `buildApp(...)` body (after the `app.route('/api/corpus', ...)` line), add:

```typescript
  // Library cloud sync — desktop pushes, iOS pulls. Both sides
  // session-gated; no license gate (library is the user's own data,
  // partitioned by session email).
  app.route('/api/library', libraryRoute(db));
```

- [ ] **Step 3: Typecheck + run all existing tests (regression check)**

```bash
pnpm typecheck
pnpm test
```

Expected: typecheck clean, all existing tests still green (we haven't changed any existing behavior, just added an unwired-up router stub).

- [ ] **Step 4: Commit**

```bash
git add src/routes/library.ts src/index.ts
git commit -m "feat(library): scaffold /api/library route (handlers 501)"
```

---

### Task 7: POST /api/library/sync (TDD)

**Files:**
- Create: `tests/library-routes.test.ts`
- Modify: `src/routes/library.ts`

- [ ] **Step 1: Write failing test**

Create `tests/library-routes.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { newDb, type IMemoryDb } from 'pg-mem';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Hono } from 'hono';
import { Database } from '../src/lib/db.js';
import { libraryRoute } from '../src/routes/library.js';
import { hashToken } from '../src/lib/sessionTokens.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

interface Rig {
  app: Hono;
  db: Database;
  mem: IMemoryDb;
}

function makeApp(): Rig {
  const mem = newDb();
  const sql = readFileSync(join(__dirname, '..', 'schema.sql'), 'utf-8');
  mem.public.none(sql);
  const adapter = mem.adapters.createPg();
  const db = new Database(new adapter.Pool());
  const app = new Hono();
  app.route('/api/library', libraryRoute(db));
  return { app, db, mem };
}

let _tokenSeq = 0;
async function insertSessionFor(db: Database, email: string): Promise<string> {
  const seq = ++_tokenSeq;
  const raw = `seed-token-${seq}-${email.replace(/[^a-z0-9]/g, '-')}`;
  await db.insertSessionToken({
    tokenHash: hashToken(raw),
    email,
    issuedAt: 1,
    expiresAt: Date.now() + 60_000,
  });
  return raw;
}

const VALID_BODY = {
  id: 'vid-abc123',
  youtubeId: 'abc123',
  sourceUrl: 'https://www.youtube.com/watch?v=abc123',
  title: 'Sample',
  durationSec: 120,
  thumbUrl: 'https://i.ytimg.com/vi/abc123/mqdefault.jpg',
  transcriptSrt: '1\n00:00:00,000 --> 00:00:02,000\nHi.\n',
  analysisJson: { cues: [] },
};

describe('POST /api/library/sync', () => {
  it('returns 401 without bearer token', async () => {
    const { app } = makeApp();
    const res = await app.request('/api/library/sync', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(VALID_BODY),
    });
    expect(res.status).toBe(401);
  });

  it('upserts an entry and returns 200', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    const res = await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(VALID_BODY),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean };
    expect(body.ok).toBe(true);
    const stored = await rig.db.getLibraryEntry('vid-abc123', 'alice@example.com');
    expect(stored).toBeDefined();
    expect(stored!.title).toBe('Sample');
    expect(stored!.ownerEmail).toBe('alice@example.com');
  });

  it('returns 400 on invalid_json body', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    const res = await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: 'not-json',
    });
    expect(res.status).toBe(400);
  });

  it('returns 400 when required fields missing', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    const res = await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: 'x' }), // missing youtubeId, etc.
    });
    expect(res.status).toBe(400);
  });
});
```

- [ ] **Step 2: Run test, verify fail**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 4 tests, all FAIL (`501 not_implemented` for the 200 case, 401 case may already pass since requireSession runs first — actually the 401 test should pass already because requireSession returns 401 before the handler runs; the others fail).

- [ ] **Step 3: Implement POST /sync handler**

Replace the `app.post('/sync', ...)` line in `src/routes/library.ts` with:

```typescript
  app.post('/sync', async (c) => {
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
    await db.upsertLibraryEntry({
      id,
      ownerEmail: email,
      youtubeId,
      sourceUrl,
      title,
      durationSec,
      thumbUrl,
      transcriptSrt,
      analysisJson,
      now: Date.now(),
    });
    return c.json({ ok: true });
  });
```

- [ ] **Step 4: Run test, verify pass**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 4/4 pass.

- [ ] **Step 5: Commit**

```bash
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "feat(library): POST /api/library/sync"
```

---

### Task 8: GET /api/library/list (TDD)

**Files:**
- Modify: `tests/library-routes.test.ts`
- Modify: `src/routes/library.ts`

- [ ] **Step 1: Add failing tests**

Append to `tests/library-routes.test.ts`:

```typescript
describe('GET /api/library/list', () => {
  it('returns 401 without bearer', async () => {
    const { app } = makeApp();
    const res = await app.request('/api/library/list');
    expect(res.status).toBe(401);
  });

  it('returns own entries only, newest first, no large fields', async () => {
    const rig = makeApp();
    const tokenA = await insertSessionFor(rig.db, 'alice@example.com');
    const tokenB = await insertSessionFor(rig.db, 'bob@example.com');
    // Alice writes two; Bob writes one
    await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${tokenA}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'a1' }),
    });
    await new Promise((r) => setTimeout(r, 5)); // ensure synced_at differs
    await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${tokenA}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'a2' }),
    });
    await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${tokenB}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'b1' }),
    });
    const res = await rig.app.request('/api/library/list', {
      headers: { authorization: `Bearer ${tokenA}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { entries: Array<Record<string, unknown>> };
    expect(body.entries.map((e) => e.id)).toEqual(['a2', 'a1']);
    // Lightweight: no transcript/analysis on the wire
    expect(body.entries[0]!.transcriptSrt).toBeUndefined();
    expect(body.entries[0]!.analysisJson).toBeUndefined();
    // But metadata is there
    expect(body.entries[0]!.title).toBe('Sample');
    expect(body.entries[0]!.youtubeId).toBe('abc123');
  });

  it('returns empty array when user has nothing synced', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    const res = await rig.app.request('/api/library/list', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { entries: unknown[] };
    expect(body.entries).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test, verify fail**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 3 new tests FAIL with `501 not_implemented` or 401-pass-but-empty.

- [ ] **Step 3: Implement GET /list handler**

Replace the `app.get('/list', ...)` line in `src/routes/library.ts`:

```typescript
  app.get('/list', async (c) => {
    const email = c.get('email' as never) as string;
    const entries = await db.listLibraryEntriesForOwner(email);
    return c.json({ entries });
  });
```

- [ ] **Step 4: Run test, verify pass**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 7/7 pass.

- [ ] **Step 5: Commit**

```bash
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "feat(library): GET /api/library/list"
```

---

### Task 9: GET /api/library/entry/:id (TDD)

**Files:**
- Modify: `tests/library-routes.test.ts`
- Modify: `src/routes/library.ts`

- [ ] **Step 1: Add failing tests**

Append to `tests/library-routes.test.ts`:

```typescript
describe('GET /api/library/entry/:id', () => {
  it('returns 401 without bearer', async () => {
    const { app } = makeApp();
    const res = await app.request('/api/library/entry/x');
    expect(res.status).toBe(401);
  });

  it('returns full entry including transcript + analysis for owner', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'vid-1' }),
    });
    const res = await rig.app.request('/api/library/entry/vid-1', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.id).toBe('vid-1');
    expect(body.title).toBe('Sample');
    expect(body.transcriptSrt).toContain('Hi.');
    expect(body.analysisJson).toEqual({ cues: [] });
    expect(body.ownerEmail).toBe('alice@example.com');
  });

  it('returns 404 for non-existent id', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    const res = await rig.app.request('/api/library/entry/nope', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(404);
  });

  it('returns 404 when requesting another user’s entry', async () => {
    const rig = makeApp();
    const tokenA = await insertSessionFor(rig.db, 'alice@example.com');
    const tokenB = await insertSessionFor(rig.db, 'bob@example.com');
    await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${tokenA}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'alice-vid' }),
    });
    const res = await rig.app.request('/api/library/entry/alice-vid', {
      headers: { authorization: `Bearer ${tokenB}` },
    });
    expect(res.status).toBe(404); // intentional: same status as non-existent (don't leak ownership)
  });
});
```

- [ ] **Step 2: Run test, verify fail**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 4 new tests FAIL.

- [ ] **Step 3: Implement GET /entry/:id**

Replace the `app.get('/entry/:id', ...)` line in `src/routes/library.ts`:

```typescript
  app.get('/entry/:id', async (c) => {
    const email = c.get('email' as never) as string;
    const id = c.req.param('id');
    if (!id) return c.json({ error: 'invalid_input' }, 400);
    const entry = await db.getLibraryEntry(id, email);
    if (!entry) return c.json({ error: 'not_found' }, 404);
    return c.json(entry);
  });
```

- [ ] **Step 4: Run test, verify pass**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 11/11 pass.

- [ ] **Step 5: Commit**

```bash
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "feat(library): GET /api/library/entry/:id with owner-scope 404"
```

---

### Task 10: DELETE /api/library/sync/:id (TDD)

**Files:**
- Modify: `tests/library-routes.test.ts`
- Modify: `src/routes/library.ts`

- [ ] **Step 1: Add failing tests**

Append to `tests/library-routes.test.ts`:

```typescript
describe('DELETE /api/library/sync/:id', () => {
  it('returns 401 without bearer', async () => {
    const { app } = makeApp();
    const res = await app.request('/api/library/sync/x', { method: 'DELETE' });
    expect(res.status).toBe(401);
  });

  it('deletes own entry and returns 200', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'vid-1' }),
    });
    const res = await rig.app.request('/api/library/sync/vid-1', {
      method: 'DELETE',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    // Confirm gone
    const after = await rig.db.getLibraryEntry('vid-1', 'alice@example.com');
    expect(after).toBeUndefined();
  });

  it('returns 404 for non-existent id', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    const res = await rig.app.request('/api/library/sync/nope', {
      method: 'DELETE',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(404);
  });

  it('returns 404 when deleting another user’s entry (no destructive side-effect)', async () => {
    const rig = makeApp();
    const tokenA = await insertSessionFor(rig.db, 'alice@example.com');
    const tokenB = await insertSessionFor(rig.db, 'bob@example.com');
    await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${tokenA}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'alice-vid' }),
    });
    const res = await rig.app.request('/api/library/sync/alice-vid', {
      method: 'DELETE',
      headers: { authorization: `Bearer ${tokenB}` },
    });
    expect(res.status).toBe(404);
    // Alice's entry untouched
    const after = await rig.db.getLibraryEntry('alice-vid', 'alice@example.com');
    expect(after).toBeDefined();
  });
});
```

- [ ] **Step 2: Run test, verify fail**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 4 new tests FAIL.

- [ ] **Step 3: Implement DELETE handler**

Replace the `app.delete('/sync/:id', ...)` line in `src/routes/library.ts`:

```typescript
  app.delete('/sync/:id', async (c) => {
    const email = c.get('email' as never) as string;
    const id = c.req.param('id');
    if (!id) return c.json({ error: 'invalid_input' }, 400);
    const removed = await db.deleteLibraryEntry(id, email);
    if (!removed) return c.json({ error: 'not_found' }, 404);
    return c.json({ ok: true });
  });
```

- [ ] **Step 4: Run test, verify pass**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 15/15 pass.

- [ ] **Step 5: Commit**

```bash
git add src/routes/library.ts tests/library-routes.test.ts
git commit -m "feat(library): DELETE /api/library/sync/:id with owner-scope 404"
```

---

### Task 11: Large-payload round-trip test

**Files:**
- Modify: `tests/library-routes.test.ts`

- [ ] **Step 1: Add large-payload test**

Append to `tests/library-routes.test.ts`:

```typescript
describe('library round-trip with realistic-size payload', () => {
  it('handles ~150 KB analysis_json without loss', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    // Build ~150 KB of analysis: 500 cues each ~300 bytes
    const cues = Array.from({ length: 500 }, (_, i) => ({
      startSec: i * 2,
      endSec: i * 2 + 2,
      en: `English sentence number ${i} that is reasonably wordy to consume bytes.`,
      zh: `第 ${i} 句话用来占字节,模拟一个有点长度的中文翻译以验证 JSONB 往返。`,
      highlights: [{ text: 'reasonably', meaning_zh: '相当地', ipa: '/ˈriːz.ən.ə.bli/' }],
    }));
    const big = { cues, summary: 'A test summary'.repeat(10) };
    const transcriptSrt = cues
      .map((c, i) => `${i + 1}\n00:00:${String(i * 2).padStart(2, '0')},000 --> 00:00:${String(i * 2 + 2).padStart(2, '0')},000\n${c.en}\n`)
      .join('\n');

    const postRes = await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'big-vid', transcriptSrt, analysisJson: big }),
    });
    expect(postRes.status).toBe(200);

    const getRes = await rig.app.request('/api/library/entry/big-vid', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(getRes.status).toBe(200);
    const got = (await getRes.json()) as { analysisJson: { cues: unknown[] } };
    expect(got.analysisJson.cues.length).toBe(500);
  });
});
```

- [ ] **Step 2: Run test, verify pass**

```bash
pnpm test tests/library-routes.test.ts
```

Expected: 16/16 pass (no implementation needed — this test exists to catch future regressions).

- [ ] **Step 3: Run FULL test suite as regression check**

```bash
pnpm test
```

Expected: every prior test still passes; total count = (whatever the baseline was) + 16 new.

- [ ] **Step 4: Run typecheck**

```bash
pnpm typecheck
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add tests/library-routes.test.ts
git commit -m "test(library): large payload round-trip regression"
```

---

### Task 12: Local smoke test against a live dev server

**Files:** none changed (just runtime verification)

- [ ] **Step 1: Start dev server with a one-off Postgres**

In one terminal, start a local Postgres for smoke (skip if you already have one):

```bash
docker run --rm -d --name pg-whatsub-smoke \
  -e POSTGRES_DB=whatsub_license \
  -e POSTGRES_USER=whatsub_license_user \
  -e POSTGRES_PASSWORD=smoketestpw \
  -p 5433:5432 postgres:15-alpine
sleep 3
docker exec -i pg-whatsub-smoke psql -U whatsub_license_user -d whatsub_license < schema.sql
```

- [ ] **Step 2: Start backend pointing at it**

In another terminal:

```bash
cd /c/Users/renjx/Desktop/whatsub-license
DATABASE_URL=postgres://whatsub_license_user:smoketestpw@localhost:5433/whatsub_license \
ADMIN_TOKEN=smoke-token \
PORT=3030 \
pnpm dev
```

Expected: `whatsub-license listening on :3030`. May warn about missing payment/mail env — fine for this smoke (those routes simply won't mount).

- [ ] **Step 3: Manually issue a session token via psql (skip auth flow)**

Standard Postgres does not ship `sha256()` SQL function (it lives in `pgcrypto` extension which isn't enabled). Precompute the token hash in Node first, then INSERT the literal hex:

```bash
TOKEN_HASH=$(node -e "console.log(require('crypto').createHash('sha256').update('smoke-bearer').digest('hex'))")
NOW_MS=$(node -e "console.log(Date.now())")
EXPIRES_MS=$(node -e "console.log(Date.now() + 86400000)")
docker exec -i pg-whatsub-smoke psql -U whatsub_license_user -d whatsub_license <<EOF
INSERT INTO session_tokens (token_hash, email, issued_at, expires_at)
VALUES ('$TOKEN_HASH', 'smoke@x.com', $NOW_MS, $EXPIRES_MS);
EOF
```

Expected: `INSERT 0 1`.

- [ ] **Step 4: Test POST /sync**

```bash
curl -i -X POST http://localhost:3030/api/library/sync \
  -H "Authorization: Bearer smoke-bearer" \
  -H "Content-Type: application/json" \
  -d '{
    "id":"smoke-vid",
    "youtubeId":"dQw4w9WgXcQ",
    "sourceUrl":"https://youtu.be/dQw4w9WgXcQ",
    "title":"Smoke Test",
    "durationSec":42,
    "thumbUrl":"https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg",
    "transcriptSrt":"1\n00:00:00,000 --> 00:00:02,000\nNever gonna.\n",
    "analysisJson":{"cues":[]}
  }'
```

Expected: `HTTP/1.1 200 OK` + `{"ok":true}`.

- [ ] **Step 5: Test GET /list**

```bash
curl -s http://localhost:3030/api/library/list -H "Authorization: Bearer smoke-bearer" | python -m json.tool
```

Expected: JSON with `entries` array containing `smoke-vid` row (no transcriptSrt / analysisJson fields).

- [ ] **Step 6: Test GET /entry/:id**

```bash
curl -s http://localhost:3030/api/library/entry/smoke-vid -H "Authorization: Bearer smoke-bearer" | python -m json.tool
```

Expected: full row including `transcriptSrt` + `analysisJson`.

- [ ] **Step 7: Test DELETE**

```bash
curl -i -X DELETE http://localhost:3030/api/library/sync/smoke-vid -H "Authorization: Bearer smoke-bearer"
# Then re-fetch and confirm 404
curl -i -s http://localhost:3030/api/library/entry/smoke-vid -H "Authorization: Bearer smoke-bearer"
```

Expected: DELETE returns `200 {"ok":true}`, follow-up GET returns `404 {"error":"not_found"}`.

- [ ] **Step 8: Tear down smoke Postgres**

```bash
docker stop pg-whatsub-smoke
```

(Container auto-removes due to `--rm`.) Ctrl-C the `pnpm dev` terminal.

- [ ] **Step 9: No commit needed** (no code changed in this task)

---

### Task 13: Apply schema to production Postgres

**Files:** none changed (production-side ops)

- [ ] **Step 1: Re-confirm schema.sql is idempotent**

```bash
cd /c/Users/renjx/Desktop/whatsub-license
git diff main -- schema.sql
```

Verify the diff only ADDS `library_entries` table + 2 indexes, no destructive changes.

- [ ] **Step 2: scp schema to server**

```bash
scp -i ~/.ssh/id_ed25519 schema.sql root@47.93.87.206:/tmp/schema-library.sql
```

Expected: file copied (~22 KB).

- [ ] **Step 3: Apply schema (idempotent, CREATE TABLE IF NOT EXISTS only adds)**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "docker exec -i enghub-postgres-1 psql -U whatsub_license_user -d whatsub_license < /tmp/schema-library.sql"
```

Expected: psql output shows mostly `NOTICE: table already exists, skipping` for existing tables, plus successful `CREATE TABLE` + `CREATE INDEX` for the new ones. Exit code 0.

- [ ] **Step 4: Verify table exists in prod**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "docker exec -i enghub-postgres-1 psql -U whatsub_license_user -d whatsub_license -c '\\d library_entries'"
```

Expected: prints the new table structure with 11 columns.

- [ ] **Step 5: No commit** (server-side op only)

---

### Task 14: Build + deploy backend container

**Files:** none changed (deploy ops)

- [ ] **Step 1: Build the image locally with buildx (NOT `docker build` per repo CLAUDE.md)**

```bash
cd /c/Users/renjx/Desktop/whatsub-license
docker buildx build --load -t whatsub-license:latest .
```

Expected: `Successfully tagged whatsub-license:latest`, `docker images | grep whatsub-license` shows it with today's timestamp.

- [ ] **Step 2: Save + ship**

```bash
docker save whatsub-license:latest | gzip > /tmp/whatsub-license.tar.gz
scp -i ~/.ssh/id_ed25519 /tmp/whatsub-license.tar.gz root@47.93.87.206:/tmp/
```

Expected: ~80-100 MB transfer.

- [ ] **Step 3: Load + restart on server**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "
  docker load < /tmp/whatsub-license.tar.gz && \
  cd /opt/whatsub && \
  docker compose --env-file .env up -d --force-recreate whatsub-license && \
  rm /tmp/whatsub-license.tar.gz
"
```

Expected: container restarted; `docker logs --tail 20 whatsub-license` shows "listening on :3002".

- [ ] **Step 4: Health check**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "docker logs --tail 30 whatsub-license"
```

Expected: no errors. Possibly `[buildApp] payment wiring omitted` (only if payment env missing, which it shouldn't be in prod).

- [ ] **Step 5: No commit needed**

---

### Task 15: Production smoke test

**Files:** none changed

- [ ] **Step 1: Insert a session token in prod for smoke (revoke immediately after)**

Precompute the hash locally, ship as a heredoc:

```bash
TOKEN_HASH=$(node -e "console.log(require('crypto').createHash('sha256').update('PROD-SMOKE-bearer-2026-05-21').digest('hex'))")
NOW_MS=$(node -e "console.log(Date.now())")
EXPIRES_MS=$(node -e "console.log(Date.now() + 600000)")
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "docker exec -i enghub-postgres-1 psql -U whatsub_license_user -d whatsub_license <<EOF
INSERT INTO session_tokens (token_hash, email, issued_at, expires_at)
VALUES ('$TOKEN_HASH', 'smoke@whatsub-test', $NOW_MS, $EXPIRES_MS);
EOF"
```

Expected: `INSERT 0 1`. (Token valid for 10 min.)

- [ ] **Step 2: POST sync via prod**

```bash
curl -i -X POST https://whatsub.eversay.cc/api/library/sync \
  -H "Authorization: Bearer PROD-SMOKE-bearer-2026-05-21" \
  -H "Content-Type: application/json" \
  -d '{
    "id":"prod-smoke-1",
    "youtubeId":"dQw4w9WgXcQ",
    "sourceUrl":"https://youtu.be/dQw4w9WgXcQ",
    "title":"Prod Smoke",
    "transcriptSrt":"1\n00:00:00,000 --> 00:00:02,000\nhi\n",
    "analysisJson":{"cues":[]}
  }'
```

Expected: `200 {"ok":true}`.

- [ ] **Step 3: GET list + entry via prod**

```bash
curl -s https://whatsub.eversay.cc/api/library/list \
  -H "Authorization: Bearer PROD-SMOKE-bearer-2026-05-21" | python -m json.tool

curl -s https://whatsub.eversay.cc/api/library/entry/prod-smoke-1 \
  -H "Authorization: Bearer PROD-SMOKE-bearer-2026-05-21" | python -m json.tool
```

Expected: list contains 1 row; entry returns full row with analysisJson.

- [ ] **Step 4: DELETE + cleanup**

```bash
curl -i -X DELETE https://whatsub.eversay.cc/api/library/sync/prod-smoke-1 \
  -H "Authorization: Bearer PROD-SMOKE-bearer-2026-05-21"

# Revoke the smoke token immediately
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "docker exec -i enghub-postgres-1 psql -U whatsub_license_user -d whatsub_license -c \"DELETE FROM session_tokens WHERE email = 'smoke@whatsub-test';\""
```

Expected: DELETE returns 200; subsequent session_tokens row count for this email is 0.

- [ ] **Step 5: No commit needed**

---

### Task 16: Merge + push

**Files:** none changed

- [ ] **Step 1: Verify current branch + uncommitted**

```bash
cd /c/Users/renjx/Desktop/whatsub-license
git status
git log --oneline main..HEAD
```

Expected: clean tree, ~10 commits on `feat/library-sync` ahead of main.

- [ ] **Step 2: Merge to main**

```bash
git checkout main
git merge --no-ff feat/library-sync -m "feat(library): cloud sync API (4 endpoints + table)"
```

Expected: clean merge.

- [ ] **Step 3: Push main**

```bash
git push origin main
```

Expected: success.

- [ ] **Step 4: Delete feature branch**

```bash
git branch -d feat/library-sync
git push origin --delete feat/library-sync
```

---

## Done criteria

All boxes checked. After this plan:
- `library_entries` table exists in prod Postgres
- 4 endpoints respond at `https://whatsub.eversay.cc/api/library/*`
- Full test suite passes locally
- ~10 commits on main, deployed image running on Aliyun ECS

Ready for Plan 2 (iOS app) and Plan 3 (desktop sync UI), both of which depend on this.
