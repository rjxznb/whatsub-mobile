# Push-to-Desktop Import Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** Phone pushes a (caption-less) YouTube URL to a backend queue; the desktop auto-polls it and runs its existing pipeline (yt-dlp download → whisper transcript → LLM analysis → cloud sync); the result appears in the Library on both devices.

**Architecture:** Backend `import_queue` table + 3 session-auth endpoints. Desktop FRONTEND poll loop reuses `import_video` (Rust: download+whisper) → `runInBackground` (LLM analysis → writes analysis.json, flips status to ready) → `library_sync_to_cloud` (sync) → marks the queue item. Phone offers "推送到桌面" on the caption-less failure path.

**Tech Stack:** Hono + node-postgres + pg-mem (backend) · React/TS + Tauri invoke (desktop) · SwiftUI (phone).

**Spec:** `docs/superpowers/specs/2026-05-23-desktop-import-queue-design.md`.

**Desktop reuse (verified):** `import_video` (commands/import.rs, `req: {source_kind:"url", source_value, quality, background}`), `runInBackground` (store/backgroundAnalyses.ts — drives runAnalysis, writes analysis.json, flips library status to "ready"; needs `{videoId, label, cues, previouslyAnalyzed:[], previousSummary:null, style}`), `library_sync_to_cloud` (commands/library_sync.rs via `lib/api/librarySync.ts`). Cues come from the produced `transcript.srt` (parse via the existing transcript loader).

---

## PART A — Backend queue (`whatsub-license`)

### Pre-flight
```bash
cd /c/Users/renjx/Desktop/whatsub-license
git checkout main && git pull && git checkout -b feat/import-queue
pnpm install && pnpm test --run 2>&1 | tail -3   # baseline green
```

### Task A1: schema

**Files:** `schema.sql`

- [ ] **Step 1:** After the library_entries block, add:
```sql
CREATE TABLE IF NOT EXISTS import_queue (
  id           TEXT PRIMARY KEY,
  owner_email  TEXT NOT NULL,
  url          TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending',  -- pending | processing | done | failed
  error        TEXT,
  created_at   BIGINT NOT NULL,
  updated_at   BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_import_queue_owner_status ON import_queue (owner_email, status);
```
Verify pg-mem parses (the node one-liner used in other schema tasks). Commit: `git add schema.sql && git commit -m "feat(import-queue): import_queue table"`

### Task A2: db methods + types (TDD)

**Files:** `src/lib/types.ts`, `src/lib/db.ts`, `tests/import-queue-db.test.ts`

- [ ] **Step 1:** `types.ts`: `export interface ImportQueueItem { id: string; ownerEmail: string; url: string; status: 'pending'|'processing'|'done'|'failed'; error: string | null; createdAt: number; updatedAt: number; }`
- [ ] **Step 2:** Failing tests (`tests/import-queue-db.test.ts`): enqueue creates pending; enqueue dedups a same owner+url still pending (returns existing); listImportQueue(owner, status?) filters; setImportStatus updates status+error+updatedAt.
- [ ] **Step 3:** `db.ts` methods:
```typescript
async enqueueImport(ownerEmail: string, url: string, now: number): Promise<{ id: string }> {
  const existing = await this.pool.query<{ id: string }>(
    `SELECT id FROM import_queue WHERE owner_email=$1 AND url=$2 AND status IN ('pending','processing') LIMIT 1`,
    [ownerEmail, url],
  );
  if (existing.rows[0]) return { id: existing.rows[0].id };
  const id = randomUUID();
  await this.pool.query(
    `INSERT INTO import_queue (id, owner_email, url, status, created_at, updated_at)
     VALUES ($1,$2,$3,'pending',$4,$4)`, [id, ownerEmail, url, now]);
  return { id };
}
async listImportQueue(ownerEmail: string, status?: string): Promise<ImportQueueItem[]> { /* SELECT … map snake→camel */ }
async setImportStatus(id: string, ownerEmail: string, status: string, error: string | null, now: number): Promise<boolean> { /* UPDATE … WHERE id AND owner_email RETURNING id */ }
```
(Import `randomUUID` from `crypto`. Map rows snake→camel like other db methods.)
- [ ] **Step 4:** Run → GREEN. typecheck. Commit: `git add src/lib/types.ts src/lib/db.ts tests/import-queue-db.test.ts && git commit -m "feat(import-queue): db enqueue/list/setStatus + TDD"`

### Task A3: routes (TDD)

**Files:** `src/routes/library.ts`, `tests/library-routes.test.ts`

- [ ] **Step 1:** Failing tests: `POST /api/library/import-queue {url}` → 200 {id}, pending; dedup returns same id; `GET /api/library/import-queue?status=pending` → owner's items; `POST /api/library/import-queue/:id/status {status:"done"}` → 200, item updated; 404 for another owner's id.
- [ ] **Step 2:** Add routes (all `requireSession(db)`), reusing the email-from-session pattern:
```typescript
app.post('/import-queue', requireSession(db), async (c) => {
  const email = c.get('email' as never) as string;
  let body: Record<string, unknown>; try { body = await c.req.json(); } catch { return c.json({error:'invalid_json'},400); }
  const url = typeof body.url === 'string' ? body.url.trim() : '';
  if (!url) return c.json({ error: 'invalid_input' }, 400);
  const { id } = await db.enqueueImport(email, url, Date.now());
  return c.json({ id });
});
app.get('/import-queue', requireSession(db), async (c) => {
  const email = c.get('email' as never) as string;
  const status = c.req.query('status');
  return c.json({ items: await db.listImportQueue(email, status) });
});
app.post('/import-queue/:id/status', requireSession(db), async (c) => {
  const email = c.get('email' as never) as string;
  const id = c.req.param('id');
  let body: Record<string, unknown>; try { body = await c.req.json(); } catch { return c.json({error:'invalid_json'},400); }
  const status = typeof body.status === 'string' ? body.status : '';
  const error = typeof body.error === 'string' ? body.error : null;
  if (!['pending','processing','done','failed'].includes(status)) return c.json({error:'invalid_input'},400);
  const ok = await db.setImportStatus(id, email, status, error, Date.now());
  return ok ? c.json({ ok: true }) : c.json({ error: 'not_found' }, 404);
});
```
- [ ] **Step 3:** Run → GREEN. typecheck + full suite. Update `API.md` (3 new endpoints). Commit: `git add src/routes/library.ts tests/library-routes.test.ts API.md && git commit -m "feat(import-queue): enqueue/list/status routes"`

### Task A4: Deploy — PAUSE for user authorization
- [ ] Merge to main; apply schema (CREATE TABLE IF NOT EXISTS, idempotent); build + ship + restart container. Smoke (temp token): POST enqueue → GET pending shows it → POST status done → GET pending empty. Revoke token.

---

## PART B — Desktop auto-poll orchestrator (`Get_Video/client`)

### Pre-flight: branch `feat/desktop-import-queue` off main.

### Task B1: queue API client (TS)

**Files:** `src/lib/api/importQueue.ts`

- [ ] **Step 1:** `enqueueImport`, `listPending`, `setStatus` — `fetch` to `https://whatsub.eversay.cc/api/library/import-queue*` with the session bearer (reuse however `librarySync.ts` gets the token — likely a Rust command returns it, or the existing api layer). Mirror `librarySync.ts`'s auth pattern. Commit.

### Task B2: orchestrator poll loop

**Files:** `src/store/importQueue.ts` (new) + wire it to start on app mount (e.g., in the root App component's effect, gated on being logged in)

- [ ] **Step 1:** A loop (setInterval ~30s, single-flight) that, when logged in:
  1. `listPending()` → take the oldest pending item; if none, return.
  2. `setStatus(id, 'processing')`.
  3. `await invoke("import_video", { req: { source_kind: "url", source_value: item.url, quality: <default>, background: true } })` → downloads + writes transcript.srt.
  4. Load the transcript cues (reuse the existing transcript→SrtCue loader the ImportModal/Player uses; e.g. `invoke("load_transcript", {videoId})` + parse, or whatever the app already does).
  5. `runInBackground({ videoId, label: item.url, cues, previouslyAnalyzed: [], previousSummary: null, style: <settings default> })`.
  6. Await the bg job reaching ready: poll `useBgAnalyses.getState().jobs[videoId].phase` until `"ready"`/done (or `"error"`). (runInBackground writes analysis.json + flips library status to ready on completion.)
  7. On ready → `await library_sync_to_cloud(videoId)` (via librarySync.ts) → `setStatus(id, 'done')`.
  8. On any error → `setStatus(id, 'failed', errorMessage)`.
  Concurrency = 1 (process one item per tick). Skip entirely if not authenticated / offline (catch + ignore).
- [ ] **Step 2:** Start the loop from the app root (only while logged in). Commit.
(NOTE: this reuses `import_video`, `runInBackground`, `library_sync_to_cloud` — study `ImportModal.tsx` for the exact import_video req fields + how it loads transcript cues + which `style` default, and mirror that sequencing headlessly. The risk is sequencing/ready-detection; test with one real caption-less URL.)

### Task B3: cargo build + typecheck + manual
- [ ] `pnpm typecheck` + `cargo build` clean. Manual: enqueue a URL (via the backend or the phone) → desktop running → it auto-imports → appears in cloud library. Commit.

### Task B4: Merge — PAUSE for user (manual `pnpm tauri dev` verify).

---

## PART C — Phone push (`whatsub-mobile`)

### Pre-flight: branch `feat/ios-push-to-desktop` off main.

### Task C1: WhatsubAPI.enqueueImport

**Files:** `whatsub-mobile/Networking/WhatsubAPI.swift`

- [ ] **Step 1:** `func enqueueImport(url: String, token: String) async throws { _ = try await post(Endpoints.library("import-queue"), body: JSONSerialization.data(withJSONObject: ["url": url]), bearer: token) }`. Commit.

### Task C2: caption-less failure → "推送到桌面" action

**Files:** `whatsub-mobile/Import/ImportViewModel.swift`, `whatsub-mobile/Import/ImportView.swift`

- [ ] **Step 1:** ViewModel: add a `State` case or flag for "extraction failed, can push" (the CaptionExtractor throws `timeout`/no-captions → set a `canPushToDesktop = true` + keep the entered URL). Add `func pushToDesktop(token:) async` → `WhatsubAPI.enqueueImport(url:)` → state `.pushedToDesktop`.
- [ ] **Step 2:** ImportView: when extraction failed with no captions, show "此视频可能没有字幕。推送到桌面端处理（桌面下载+whisper 转录，需桌面在线）？" + a "推送到桌面" button → `vm.pushToDesktop`. On success: "已推送，桌面端在线时会自动处理，完成后会出现在 Library。" Commit.

### Task C3: CI + Merge + TestFlight — PAUSE for user.

---

## End-to-end
Phone: import a caption-less YouTube video → extraction fails → "推送到桌面" → (desktop running) auto-downloads + whisper + analyzes + syncs → video appears in Library (both devices) with a whisper transcript + analysis.

## Done criteria
- Backend queue endpoints live + tested. Desktop auto-polls + processes via its existing pipeline. Phone pushes caption-less videos to the queue. End-to-end works with the desktop online.

## Notes
- Desktop must be running + logged in to process (async; communicated on the phone).
- The orchestrator is the heaviest part — it headlessly drives UI-normally-driven functions; sequencing + ready-detection + per-step failure marking are the care points.
- Failures marked `failed` with a reason (surface later via a phone status view — out of scope v1; the user can re-push).
