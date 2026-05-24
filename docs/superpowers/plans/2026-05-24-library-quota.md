# Library Sync Quota Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap per-user OSS-hosted videos (free 3 / desktop-license 50), enforced server-side at the push (`/import-queue`) and at sync (`/sync`), to bound OSS cost and make more storage a reason to buy the license.

**Architecture:** Backend is the core — three small `COUNT`/exists db methods + quota checks at the push endpoint (early, counts in-flight) and the sync endpoint (backstop) + a `GET /quota`. Tiers reuse the existing `hasActiveLicense` (no IAP). Desktop + iOS just surface the `quota_exceeded` error.

**Tech Stack:** Hono + node-postgres (pg-mem tests) backend · Rust/React desktop · SwiftUI iOS (iOS 16 — no iOS-17 APIs). 

**Spec:** `docs/superpowers/specs/2026-05-24-library-quota-design.md`

**Repos + branches:** backend `whatsub-license` (branch `feat/library-quota`), desktop `Get_Video` (branch `feat/library-quota`), iOS `whatsub-mobile` (branch `feat/library-quota`, spec/plan already committed here). Backend + desktop commits may be pushed; iOS commits stay local until the single end push (Task 5). Prod deploy + the TestFlight push need explicit user authorization.

---

## File Structure
- `whatsub-license/src/lib/db.ts` — add `ownerVideoCount`, `entryHasVideoKey`, `pendingImportCount`.
- `whatsub-license/src/routes/library.ts` — quota check in `POST /import-queue` + `POST /sync`; new `GET /quota`.
- `whatsub-license/tests/library-quota-db.test.ts` — db method tests.
- `Get_Video/client/src/lib/api/librarySync.ts` — `friendlySyncError` maps `quota_exceeded`.
- `Get_Video/client/src/store/importQueue.ts` — `friendlyQueueError` maps `quota_exceeded`.
- `whatsub-mobile/whatsub-mobile/Networking/APIError.swift` — `quota_exceeded` Chinese message.
- `whatsub-mobile/whatsub-mobile/Import/ImportViewModel.swift` — `pushToDesktop` shows the quota message.

---

## Task 1: Backend count/exists db methods (TDD)

**Files:**
- Modify: `whatsub-license/src/lib/db.ts` (add 3 methods near the library/import-queue methods, e.g. after `setImportStatus` ~line 1911)
- Test: `whatsub-license/tests/library-quota-db.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `tests/library-quota-db.test.ts` (match the existing db-test harness — search `tests/` for `makeDb` / how a `Database` over pg-mem is built, and reuse it):
```ts
import { describe, it, expect } from 'vitest';
// import the same test-db factory the other db tests use (e.g. makeDb from a shared helper)

function entry(id: string, owner: string, videoKey?: string) {
  return { id, ownerEmail: owner, youtubeId: id, sourceUrl: 'https://x/'+id, title: 't',
           transcriptSrt: 's', analysisJson: {}, videoKey, now: 1 } as const;
}

describe('library quota db methods', () => {
  it('ownerVideoCount counts only video_key entries, per owner', async () => {
    const db = await makeDb();
    await db.upsertLibraryEntry(entry('v1', 'a@b.com', 'k1'));
    await db.upsertLibraryEntry(entry('c1', 'a@b.com'));            // no videoKey
    await db.upsertLibraryEntry(entry('v2', 'other@b.com', 'k2'));
    expect(await db.ownerVideoCount('a@b.com')).toBe(1);
    expect(await db.ownerVideoCount('other@b.com')).toBe(1);
    expect(await db.ownerVideoCount('nobody@b.com')).toBe(0);
  });

  it('entryHasVideoKey reflects whether the row has an OSS object', async () => {
    const db = await makeDb();
    await db.upsertLibraryEntry(entry('v1', 'a@b.com', 'k1'));
    await db.upsertLibraryEntry(entry('c1', 'a@b.com'));
    expect(await db.entryHasVideoKey('v1', 'a@b.com')).toBe(true);
    expect(await db.entryHasVideoKey('c1', 'a@b.com')).toBe(false);
    expect(await db.entryHasVideoKey('missing', 'a@b.com')).toBe(false);
  });

  it('pendingImportCount counts pending+processing only', async () => {
    const db = await makeDb();
    await db.enqueueImport('a@b.com', 'https://x/1', 1);
    const { id } = await db.enqueueImport('a@b.com', 'https://x/2', 1);
    await db.setImportStatus(id, 'a@b.com', 'done', null, 2);       // done → not counted
    expect(await db.pendingImportCount('a@b.com')).toBe(1);
    expect(await db.pendingImportCount('other@b.com')).toBe(0);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run (from `whatsub-license`): `pnpm test -- library-quota`. Expected: FAIL — methods undefined.

- [ ] **Step 3: Implement the methods**

In `src/lib/db.ts`, add (matching the existing `COUNT(*)::text` + `parseInt` style used by `getStats`/order counts):
```ts
  /** Count the owner's OSS-hosted videos (entries with a video_key) — the OSS cost driver. */
  async ownerVideoCount(ownerEmail: string): Promise<number> {
    const res = await this.pool.query<{ n: string }>(
      `SELECT COUNT(*)::text AS n FROM library_entries
        WHERE owner_email = $1 AND video_key IS NOT NULL`,
      [ownerEmail],
    );
    return parseInt(res.rows[0]?.n ?? '0', 10);
  }

  /** Does this entry already have an OSS object? (Re-syncing it adds no new OSS.) */
  async entryHasVideoKey(id: string, ownerEmail: string): Promise<boolean> {
    const res = await this.pool.query<{ video_key: string | null }>(
      `SELECT video_key FROM library_entries WHERE id = $1 AND owner_email = $2 LIMIT 1`,
      [id, ownerEmail],
    );
    return res.rows[0]?.video_key != null;
  }

  /** In-flight pushes that will become OSS videos (count toward quota at push time). */
  async pendingImportCount(ownerEmail: string): Promise<number> {
    const res = await this.pool.query<{ n: string }>(
      `SELECT COUNT(*)::text AS n FROM import_queue
        WHERE owner_email = $1 AND status IN ('pending', 'processing')`,
      [ownerEmail],
    );
    return parseInt(res.rows[0]?.n ?? '0', 10);
  }
```

- [ ] **Step 4: Run the tests** — `pnpm test -- library-quota`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C C:\Users\renjx\Desktop\whatsub-license checkout -b feat/library-quota   # if not already
git -C C:\Users\renjx\Desktop\whatsub-license add src/lib/db.ts tests/library-quota-db.test.ts
git -C C:\Users\renjx\Desktop\whatsub-license commit -m "feat(library): owner video count + entryHasVideoKey + pendingImportCount"
```

---

## Task 2: Backend quota enforcement + endpoint

**Files:**
- Modify: `whatsub-license/src/routes/library.ts` (`POST /import-queue`, `POST /sync`, add `GET /quota`)

- [ ] **Step 1: Add the quota limit helper + `POST /import-queue` early check**

In `src/routes/library.ts`, near the top of the route module (inside the function, before the routes) add a small helper:
```ts
  const quotaLimit = (c: { get: (k: never) => unknown }) =>
    (c.get('hasActiveLicense' as never) ? 50 : 3);
```
Then in `app.post('/import-queue', ...)`, AFTER the `url` validation and BEFORE `db.enqueueImport`:
```ts
    const limit = quotaLimit(c);
    const committed = (await db.ownerVideoCount(email)) + (await db.pendingImportCount(email));
    if (committed >= limit) {
      return c.json({ error: 'quota_exceeded', used: committed, limit }, 403);
    }
```

- [ ] **Step 2: `POST /sync` backstop check**

In `app.post('/sync', ...)`, AFTER `videoKey` is parsed and BEFORE `await db.upsertLibraryEntry({...})`:
```ts
    if (videoKey && !(await db.entryHasVideoKey(id, email))) {
      const used = await db.ownerVideoCount(email);
      const limit = quotaLimit(c);
      if (used >= limit) {
        return c.json({ error: 'quota_exceeded', used, limit }, 403);
      }
    }
```

- [ ] **Step 3: `GET /quota` endpoint**

Add (e.g. after the `/list` route):
```ts
  app.get('/quota', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    const used = await db.ownerVideoCount(email);
    return c.json({ used, limit: quotaLimit(c) });
  });
```

- [ ] **Step 4: Typecheck/build** — `pnpm run build` (or `pnpm typecheck`) in `whatsub-license`. Expected: no type errors. (If the repo has Hono route tests, add one mirroring them: a session with `hasActiveLicense=false`, push 3 videos' worth → 4th push 403; otherwise the db-method tests in Task 1 + the deploy smoke test in Task 5 cover it.)

- [ ] **Step 5: Commit**

```bash
git -C C:\Users\renjx\Desktop\whatsub-license add src/routes/library.ts
git -C C:\Users\renjx\Desktop\whatsub-license commit -m "feat(library): enforce OSS-video quota at /import-queue + /sync + GET /quota"
```

> **Deploy** happens in Task 5 (with user authorization). The desktop/iOS error handling (Tasks 3-4) is harmless before deploy (no quota error fires until the backend enforces).

---

## Task 3: Desktop — surface the quota error

**Files:**
- Modify: `Get_Video/client/src/lib/api/librarySync.ts` (`friendlySyncError`)
- Modify: `Get_Video/client/src/store/importQueue.ts` (`friendlyQueueError`)

- [ ] **Step 1: Map `quota_exceeded` in `friendlySyncError`**

The Rust returns the body on non-2xx as `"http 403: {json}"`. In `friendlySyncError`, BEFORE the generic `if (raw.startsWith("http "))`:
```ts
  if (raw.includes("quota_exceeded")) {
    const m = raw.match(/"used":\s*(\d+).*?"limit":\s*(\d+)/);
    const tail = m ? `（${m[1]}/${m[2]}）` : "";
    return `云端视频已达上限${tail}：删掉一些已同步的，或购买授权解锁 50 个`;
  }
```

- [ ] **Step 2: Map it in the queue worker's `friendlyQueueError`**

In `src/store/importQueue.ts`, in `friendlyQueueError(raw)`, add at the top (before the login check):
```ts
  if (raw.includes("quota_exceeded")) {
    const m = raw.match(/"used":\s*(\d+).*?"limit":\s*(\d+)/);
    const tail = m ? `（${m[1]}/${m[2]}）` : "";
    return `云端视频已达上限${tail}：删掉一些或购买授权解锁 50 个`;
  }
```

- [ ] **Step 3: Typecheck** — `pnpm typecheck` in `Get_Video/client`. Expected: clean.

- [ ] **Step 4: Commit**

```bash
git -C C:\Users\renjx\Desktop\Get_Video checkout -b feat/library-quota   # if not already
git -C C:\Users\renjx\Desktop\Get_Video add client/src/lib/api/librarySync.ts client/src/store/importQueue.ts
git -C C:\Users\renjx\Desktop\Get_Video commit -m "feat(library): friendly 'cloud full' message on quota_exceeded (sync + queue)"
```

---

## Task 4: iOS — show the quota message on push (LOCAL commits, no push)

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Networking/APIError.swift`
- Modify: `whatsub-mobile/whatsub-mobile/Import/ImportViewModel.swift`

`WhatsubAPI.enqueueImport` uses `postExpectingOk`, which throws `APIError.server(code, errorString)` on non-2xx — so a 403 quota reject throws `APIError.server(403, "quota_exceeded")`.

- [ ] **Step 1: Add the Chinese message in `APIError.chinese`**

In `APIError.swift`, in the `case .server(let code, let err): switch err { ... }`, add a case before `default`:
```swift
            case "quota_exceeded": return "云端视频已达上限，先在 Library 删一个，或购买授权解锁更多"
```

- [ ] **Step 2: `pushToDesktop` surfaces the APIError message**

In `ImportViewModel.swift`, the `pushToDesktop(token:)` catch currently is `catch { state = .error(error.localizedDescription) }`. Replace it so an `APIError` shows its `.chinese`:
```swift
        } catch let e as APIError {
            state = .error(e.chinese)
        } catch {
            state = .error(error.localizedDescription)
        }
```
(The quota reject now shows "云端视频已达上限…" instead of a generic error, and the push is correctly NOT marked as succeeded.)

- [ ] **Step 3: Commit (LOCAL, do not push)**

```bash
git -C C:\Users\renjx\Desktop\whatsub-mobile add whatsub-mobile/Networking/APIError.swift whatsub-mobile/Import/ImportViewModel.swift
git -C C:\Users\renjx\Desktop\whatsub-mobile commit -m "feat(ios/import): show 云端已满 quota message when push is rejected"
```

---

## Task 5: Integration — deploy backend, push desktop, push iOS

- [ ] **Step 1: Deploy backend (with user authorization)**

Get explicit user authorization, then push `feat/library-quota` + merge to main + deploy `whatsub-license` to prod (the documented `docker buildx build --load` → `docker save | scp` → `ssh docker load + compose up -d --force-recreate`). Smoke-test:
```bash
# whoami-style: quota route requires a session → 401 (route exists), not 404:
curl -s --noproxy '*' -o /dev/null -w "%{http_code}\n" https://whatsub.eversay.cc/api/library/quota
```
Expected: `401`.

- [ ] **Step 2: Merge + push desktop**

Push `feat/library-quota` on `Get_Video`, merge to main, push. (No deploy — desktop is a local app; the change ships in the next desktop build.)

- [ ] **Step 3: Push iOS (single TestFlight trigger, with user authorization)**

Add a `CLAUDE.md` line noting the quota. Commit on the iOS branch, then merge `feat/library-quota` → main + push (the ONE TestFlight-triggering push). If Archive fails "maximum number of certificates", revoke an old cert at developer.apple.com → Certificates, then `gh run rerun <run-id>`.

- [ ] **Step 4: Manual e2e**

As a free account (no license): sync/push until 3 OSS videos, then the 4th push from the phone → "云端视频已达上限"; desktop ☁️ sync of a 4th → the same message on the button. Activate a license → limit becomes 50. Delete one synced video → can add again.

---

## Self-Review

**1. Spec coverage:**
- Count OSS videos only → Task 1 `ownerVideoCount` (`video_key IS NOT NULL`). ✓
- Free 3 / license 50 via `hasActiveLicense` → Task 2 `quotaLimit`. ✓
- Push-time early check (synced + in-flight) → Task 2 Step 1 (`ownerVideoCount + pendingImportCount`). ✓
- Sync backstop, re-sync allowed (entryHasVideoKey), captions-only unaffected → Task 2 Step 2. ✓
- `GET /quota` → Task 2 Step 3. ✓
- Desktop surfaces it (SyncButton via friendlySyncError; queue worker via friendlyQueueError) → Task 3. ✓
- iOS shows it on push → Task 4. ✓
- Grandfather (no retroactive delete) → inherent (we only block new syncs; nothing deletes). ✓
- No IAP / no new entitlement → confirmed (reuses hasActiveLicense). ✓

**2. Placeholder scan:** No TBD/vague. Every code step has full code. Task 2 Step 4 notes route-test "if a harness exists" — the db logic is TDD'd in Task 1 + manual e2e in Task 5 covers the wiring (acceptable; the route handler is thin).

**3. Type consistency:**
- `ownerVideoCount(email)`/`entryHasVideoKey(id,email)`/`pendingImportCount(email)` — defined Task 1, called in Task 2 with matching args. ✓
- `quota_exceeded` error key — emitted by backend (Task 2), matched by desktop `friendlySyncError`/`friendlyQueueError` (Task 3) + iOS `APIError.chinese` `case "quota_exceeded"` (Task 4). ✓
- `APIError.server(403, "quota_exceeded")` — `.server(Int, String?)` exists in APIError.swift; `postExpectingOk` throws it; `pushToDesktop` catches `APIError` → `.chinese`. ✓
- `quotaLimit(c)` reads `c.get('hasActiveLicense')` — set by `requireSession` (auth.ts). ✓
- No iOS-17 APIs (APIError string + a catch clause). ✓

No gaps found.
