# Library Delete (mobile swipe → remove from cloud) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal (A+B):** iOS Library: swipe-left a video card → red trash → deletes it from the cloud (backend row + OSS video). Desktop reflects the deletion by clearing the stale "✓ synced" badge on its next reconcile (the local video file is kept — the desktop is the master copy).

**Architecture:** Reuse the existing `DELETE /api/library/sync/:id` (already used by the desktop "unsync"). Extend it to also delete the OSS object (via the entry's `video_key`). iOS adds native `.swipeActions` + a confirm dialog + a `deleteLibraryEntry` API call. Desktop's `library_list_synced` gains a reconcile step (clear local `syncedAt` for entries gone from the cloud) and is called on Library mount.

**Tech Stack:** Hono + ali-oss (backend) · SwiftUI (iOS) · Rust + React (desktop).

**Scope decision (agreed):** "Delete on mobile" = remove from cloud (unsync). Desktop keeps the local source files (master copy). NOT deleting desktop local files (that would need a tombstone/deletion-queue — out of scope, undesirable).

---

## PART A — Backend OSS cleanup on delete (`whatsub-license`)

### Pre-flight
```bash
cd /c/Users/renjx/Desktop/whatsub-license
git checkout main && git pull && git checkout -b feat/library-delete-oss
pnpm install && pnpm test --run 2>&1 | tail -3   # baseline green (~317)
```

### Task A1: oss.deleteObject + deleteLibraryEntry returns video_key + route cleanup (TDD)

**Files:** `src/lib/oss.ts`, `src/lib/db.ts`, `src/routes/library.ts`, `tests/library-routes.test.ts`

- [ ] **Step 1:** `src/lib/oss.ts` — add a best-effort delete (ports Enghub `OssStorageService.delete`):
```typescript
/** Best-effort delete of an OSS object. Swallows errors (a failed cleanup
 *  must not block the DB-row deletion). */
export async function deleteObject(objectKey: string): Promise<void> {
  try {
    await client().delete(objectKey);
  } catch {
    /* best-effort — orphaned object is acceptable, missing row is not */
  }
}
```

- [ ] **Step 2:** `src/lib/db.ts` — change `deleteLibraryEntry` to return the deleted entry's `video_key` (so the route can clean up OSS). Grep callers first (`grep -rn deleteLibraryEntry src tests`) — the only caller should be the DELETE route; update it in Step 4.
```typescript
  async deleteLibraryEntry(id: string, ownerEmail: string): Promise<{ removed: boolean; videoKey: string | null }> {
    const res = await this.pool.query<{ video_key: string | null }>(
      `DELETE FROM library_entries WHERE id = $1 AND owner_email = $2 RETURNING video_key`,
      [id, ownerEmail],
    );
    const row = res.rows[0];
    return { removed: !!row, videoKey: row?.video_key ?? null };
  }
```

- [ ] **Step 3:** Write/adjust tests in `tests/library-routes.test.ts`. The existing DELETE test (if any) likely checks the boolean path — update it. Add:
```typescript
it('DELETE /sync/:id removes the row (200) then 404 on re-delete', async () => {
  const rig = makeApp();
  const token = await insertSessionFor(rig.db, 'alice@example.com');
  await rig.app.request('/api/library/sync', {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...VALID_BODY, id: 'del1', videoKey: 'whatsub/library/abc/del1.mp4' }),
  });
  const d1 = await rig.app.request('/api/library/sync/del1', { method: 'DELETE', headers: { authorization: `Bearer ${token}` } });
  expect(d1.status).toBe(200);
  const list = await (await rig.app.request('/api/library/list', { headers: { authorization: `Bearer ${token}` } })).json() as any;
  expect(list.entries.find((e: any) => e.id === 'del1')).toBeUndefined();
  const d2 = await rig.app.request('/api/library/sync/del1', { method: 'DELETE', headers: { authorization: `Bearer ${token}` } });
  expect(d2.status).toBe(404);
});
```
(The route calls `deleteObject` best-effort; in the test env it'll try the dummy-cred OSS client + swallow the failure — the row delete + 200 still happen. If `deleteObject` somehow throws synchronously, the try/catch in it prevents it; verify the route still returns 200.)
Run → RED (deleteLibraryEntry return shape changed → route compile/type error until Step 4).

- [ ] **Step 4:** `src/routes/library.ts` — update the DELETE handler:
```typescript
import { deleteObject, ossConfigured } from '../lib/oss.js'; // ensure imported

  app.delete('/sync/:id', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    const id = c.req.param('id');
    if (!id) return c.json({ error: 'invalid_input' }, 400);
    const { removed, videoKey } = await db.deleteLibraryEntry(id, email);
    if (!removed) return c.json({ error: 'not_found' }, 404);
    if (videoKey && ossConfigured()) {
      await deleteObject(videoKey); // best-effort OSS video cleanup
    }
    return c.json({ ok: true });
  });
```

- [ ] **Step 5:** Run → GREEN. `pnpm typecheck && pnpm test --run 2>&1 | tail -4`.
- [ ] **Step 6:** Update `API.md`: note that `DELETE /api/library/sync/:id` now also deletes the OSS video object. Commit:
```bash
git add src/lib/oss.ts src/lib/db.ts src/routes/library.ts tests/library-routes.test.ts API.md
git commit -m "feat(library/delete): DELETE also cleans up the OSS video object"
```

### Task A2: Deploy — PAUSE for user authorization
- [ ] Merge to main; build + ship + `docker compose up -d --force-recreate whatsub-license` (no schema change). Smoke: a temp-token DELETE of a non-existent id → 404 (proves route live). (Env already set from the video feature.)

---

## PART B — iOS swipe-to-delete (`whatsub-mobile`)

### Pre-flight
```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git checkout main && git pull && git checkout -b feat/ios-library-delete
```

### Task B1: WhatsubAPI delete primitive + method

**Files:** `whatsub-mobile/Networking/WhatsubAPI.swift`

- [ ] **Step 1:** Add a `delete` HTTP primitive next to `get`/`post`:
```swift
    private func delete(_ url: URL, bearer: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyBearer(&req, bearer)
        return try await send(req)
    }
```
- [ ] **Step 2:** Add the library method (next to listLibrary/libraryEntry):
```swift
    func deleteLibraryEntry(id: String, token: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await delete(Endpoints.library("sync/\(encoded)"), bearer: token)
    }
```
- [ ] **Step 3:** Commit: `git add whatsub-mobile/Networking/WhatsubAPI.swift && git commit -m "feat(ios/library): WhatsubAPI deleteLibraryEntry"`

### Task B2: ViewModel delete + swipe action + confirm

**Files:** `whatsub-mobile/Library/LibraryViewModel.swift`, `whatsub-mobile/Library/LibraryView.swift`

- [ ] **Step 1:** `LibraryViewModel` — add:
```swift
    func delete(_ id: String, token: String) async {
        do {
            try await WhatsubAPI.shared.deleteLibraryEntry(id: id, token: token)
            entries.removeAll { $0.id == id }
        } catch {
            errorMessage = "删除失败，请稍后重试"
        }
    }
```
- [ ] **Step 2:** `LibraryView` — on the List row `NavigationLink`, add a trailing swipe action + a confirmation dialog. Add `@State private var pendingDelete: LibraryListItem?`. On the row:
```swift
                NavigationLink(value: entry.id) {
                    LibraryRow(entry: entry)
                }
                .listRowBackground(Color.whatsubBgElev)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingDelete = entry } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
```
And add a confirmation dialog on the List (or its container):
```swift
            .confirmationDialog(
                "从云端删除「\(pendingDelete?.title ?? "")」？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let e = pendingDelete, let token = appState.session?.sessionToken {
                        Task { await vm.delete(e.id, token: token); pendingDelete = nil }
                    }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("将从云端移除该视频（含已上传的视频文件）。桌面端的本地副本保留，可重新同步。")
            }
```
(`.swipeActions` is iOS 15+; `role: .destructive` renders the button red automatically. Place `.confirmationDialog` where `pendingDelete`/`appState`/`vm` are in scope — on the List inside `content`.)
- [ ] **Step 3:** Commit: `git add whatsub-mobile/Library/LibraryViewModel.swift whatsub-mobile/Library/LibraryView.swift && git commit -m "feat(ios/library): swipe-to-delete + confirm (remove from cloud)"`

### Task B3: Push + CI
- [ ] Push `feat/ios-library-delete`; watch CI. Watch-outs: `.confirmationDialog` binding, `.swipeActions` placement (must be on a row inside a `List`). Fix + re-push until green.

### Task B4: Merge + TestFlight — PAUSE for user authorization
- [ ] **STOP. Get authorization** (TestFlight + cert slots). Merge → main; watch testflight.yml.

---

## PART C — Desktop reconcile (`Get_Video/client`)

### Pre-flight
```bash
cd /c/Users/renjx/Desktop/Get_Video/client
git checkout main && git pull && git checkout -b feat/desktop-sync-reconcile
```

### Task C1: library_list_synced clears stale syncedAt

**Files:** `src-tauri/src/commands/library_sync.rs`

- [ ] **Step 1:** In `library_list_synced`, after building `out` (the cloud entries) and BEFORE `Ok(out)`, reconcile the local index — clear `synced_at` for local videos that have it set but are no longer in the cloud list:
```rust
    // Reconcile: a video deleted from the cloud elsewhere (e.g. the mobile app)
    // should lose its local "synced" badge. Clear synced_at for local entries
    // with it set that are absent from the cloud list. Best-effort — never fail
    // the listing on a reconcile hiccup.
    let cloud_ids: std::collections::HashSet<&str> =
        out.iter().map(|e| e.id.as_str()).collect();
    if let Ok(mut library) = crate::commands::library::read_index() {
        let mut changed = false;
        for v in library.videos.iter_mut() {
            if v.synced_at.is_some() && !cloud_ids.contains(v.id.as_str()) {
                v.synced_at = None;
                v.sync_error = None;
                changed = true;
            }
        }
        if changed {
            let _ = crate::commands::library::write_index(&library);
        }
    }
```
(Verify `CloudLibraryEntry` has an `id` field of type String — it's deserialized from the backend `/list` entries which include `id`. If the field is named differently, adapt. `read_index`/`write_index` are `pub(crate)` in `commands::library`.)
- [ ] **Step 2:** `cargo build --quiet` → clean; `cargo test --quiet` → green. Commit: `git add src-tauri/src/commands/library_sync.rs && git commit -m "feat(sync): library_list_synced clears stale local syncedAt (reconcile)"`

### Task C2: Call listSynced on Library mount (refresh badges)

**Files:** `src/pages/Library.tsx` (+ maybe `src/lib/api/librarySync.ts` is already imported in CloudSyncManager)

- [ ] **Step 1:** Read `Library.tsx` to find how it loads the library list into state (the read-index invoke + setter) and its mount `useEffect`s. Add a mount-time fire-and-forget reconcile:
```typescript
import { listSynced } from "../lib/api/librarySync";
// in a useEffect that runs once on mount, AFTER the initial library load:
useEffect(() => {
  // Trigger the Rust-side reconcile (clears stale syncedAt for cloud-deleted
  // entries), then reload the library so badges refresh.
  listSynced().then(() => { /* reload library list — call the same loader used on mount */ }).catch(() => {});
}, []);
```
Wire `reload` to whatever function re-reads the library index into state (reuse the existing loader; do NOT duplicate it). If the existing mount effect already calls a `loadLibrary()`, call `listSynced().then(loadLibrary).catch(()=>{})`.
- [ ] **Step 2:** `pnpm typecheck` → clean. Commit: `git add src/pages/Library.tsx && git commit -m "feat(sync): reconcile synced badges on Library mount"`

### Task C3: Merge — PAUSE for user
- [ ] Merge `feat/desktop-sync-reconcile` → Get_Video main (no deploy — desktop ships on release). User can `pnpm tauri dev` to verify badges clear after a mobile delete.

---

## End-to-end verification
1. iOS: swipe a video card left → red 删除 → confirm → it disappears from the list.
2. Backend (temp token): `GET /api/library/list` no longer includes it; `curl -I` the old `videoUrl` → 403/404 (OSS object gone).
3. Desktop: relaunch (or open Library) → that video's ✓ badge is cleared (shows unsynced); the local file is still present.

## Done criteria
- iOS swipe-left → red trash → confirm → removes from cloud (row + OSS video).
- Desktop reconciles the stale synced badge on next Library mount; local files kept.
- Backend DELETE cleans up the OSS object (no orphans); tests green; CI green.

## Notes
- Same `DELETE /api/library/sync/:id` powers both mobile-delete and desktop-unsync → both now clean up OSS. Consistent.
- Desktop local source files are intentionally kept (master copy). Re-sync re-uploads.
- Confirm dialog guards against accidental swipes; deletion is recoverable by re-syncing from desktop.
