# Generic URL Import (desktop queue path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let whatSub import a video from any yt-dlp-supported URL (Bilibili as the first validation source) by routing it through the existing desktop queue → whisper → LLM → OSS self-host → sync, so it appears in the Library watchable without VPN.

**Architecture:** Three small, ordered changes across three repos. Backend gains an atomic queue claim (fixes multi-desktop double-pick). Desktop generalizes its id extraction + cloud sync (today both hard-fail on non-YouTube) and claims items atomically. iOS routes non-YouTube URLs straight to the desktop queue (skip caption extraction) and guards playback so a non-YouTube entry never falls back to the YouTube embed. Source is derived (no schema migration); cookies/login + failures are handled desktop-side in v1.

**Tech Stack:** Hono + node-postgres (pg-mem tests) backend · Rust/Tauri + React/TS (cargo + vitest/pnpm) desktop · SwiftUI iOS (XCTest, built in CI).

**Spec:** `docs/superpowers/specs/2026-05-23-generic-url-import-design.md`

---

## File Structure

**Backend (`C:\Users\renjx\Desktop\whatsub-license`)** — branch `feat/generic-url-import`
- Modify `src/lib/db.ts` — add `claimImportItem(id, ownerEmail, now)` (atomic pending→processing).
- Modify `src/routes/library.ts` — add `POST /import-queue/:id/claim` route.
- Test `test/` — claim atomicity (pg-mem).

**Desktop (`C:\Users\renjx\Desktop\Get_Video`, client in `client/`)** — branch `feat/generic-url-import`
- Modify `client/src-tauri/src/core/ids.rs` — add `id_from_bilibili_url`.
- Modify `client/src-tauri/src/commands/import.rs` — wire bilibili into the id resolution chain.
- Modify `client/src-tauri/src/commands/library_sync.rs` — generic id + conditional thumbUrl (remove `not_youtube` hard-fail).
- Modify `client/src/lib/api/importQueue.ts` — add `claimItem(id)`.
- Modify `client/src/store/importQueue.ts` — atomic claim + friendly failure message.

**iOS (`C:\Users\renjx\Desktop\whatsub-mobile`)** — branch `feat/generic-url-import` (ALREADY CREATED; spec already committed here)
- Create `whatsub-mobile/Networking/VideoSource.swift` — source classifier + YouTube-id-shape check.
- Modify `whatsub-mobile/Import/ImportViewModel.swift` — route non-YouTube URLs to the push flow (new `.needsDesktop` state).
- Modify `whatsub-mobile/Import/ImportView.swift` — render `.needsDesktop`; update idle copy.
- Modify `whatsub-mobile/Library/LibraryDetailView.swift` — playback guard + desktop-only placeholder.
- Test `whatsub-mobileTests/VideoSourceTests.swift` — classifier fixtures (runs in CI).

**Push policy:** Backend + desktop commits may be pushed (no TestFlight). iOS commits stay LOCAL on the branch; the single push that triggers CI+TestFlight happens once at the very end (Task 11), bundling all iOS changes + the already-local docs.

---

## Task 1: Backend — atomic queue claim (db method)

**Files:**
- Modify: `src/lib/db.ts:1896-1911` (add new method after `setImportStatus`)
- Test: the repo's db test file for import_queue (search for `enqueueImport` in `test/`; add the case there)

- [ ] **Step 1: Write the failing test**

Find the existing import-queue db test (search `test/` for `enqueueImport`). Add this case (adjust the harness/import to match the file's existing style — it uses pg-mem via the same `Database` class):

```ts
it('claimImportItem is atomic: only the first claim of a pending item wins', async () => {
  const db = await makeTestDb();              // same factory the other db tests use
  const { id } = await db.enqueueImport('a@b.com', 'https://x/v', 1000);

  const first = await db.claimImportItem(id, 'a@b.com', 1001);
  const second = await db.claimImportItem(id, 'a@b.com', 1002);

  expect(first).toBe(true);
  expect(second).toBe(false);                 // already processing → not re-claimable

  const items = await db.listImportQueue('a@b.com', 'processing');
  expect(items.map((i) => i.id)).toContain(id);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run (from `whatsub-license`): `pnpm test -- import` (or the repo's test command). Expected: FAIL — `db.claimImportItem is not a function`.

- [ ] **Step 3: Implement `claimImportItem`**

In `src/lib/db.ts`, immediately after `setImportStatus` (closes at line 1911), add:

```ts
  /**
   * Atomically claim a pending item for processing. The `AND status='pending'`
   * guard means only one caller wins even if multiple desktops poll the same
   * item concurrently. Returns true if THIS call flipped it pending→processing,
   * false if it was already claimed / done / missing. Mirrors the order-claim
   * pattern in markOrderPaidAndMintLicense.
   */
  async claimImportItem(id: string, ownerEmail: string, now: number): Promise<boolean> {
    const res = await this.pool.query<{ id: string }>(
      `UPDATE import_queue
          SET status = 'processing', updated_at = $3
        WHERE id = $1 AND owner_email = $2 AND status = 'pending'
        RETURNING id`,
      [id, ownerEmail, now],
    );
    return (res.rowCount ?? 0) > 0;
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm test -- import`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git checkout -b feat/generic-url-import   # if not already on it
git add src/lib/db.ts test/
git commit -m "feat(library): atomic import-queue claim (fix multi-desktop double-pick)"
```

---

## Task 2: Backend — claim route

**Files:**
- Modify: `src/routes/library.ts:134` (add route after the `:id/status` route, before `return app`)

- [ ] **Step 1: Add the route**

In `src/routes/library.ts`, after the `app.post('/import-queue/:id/status', …)` block (ends line 134) and before `return app;`:

```ts
  app.post('/import-queue/:id/claim', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    const id = c.req.param('id');
    const claimed = await db.claimImportItem(id, email, Date.now());
    return c.json({ claimed });
  });
```

- [ ] **Step 2: Typecheck + build**

Run: `pnpm run build` (or `pnpm typecheck`). Expected: no type errors.

- [ ] **Step 3: Commit + deploy note**

```bash
git add src/routes/library.ts
git commit -m "feat(library): POST /import-queue/:id/claim endpoint"
```

> **Deploy:** This route must be live before the desktop change (Task 6) works against prod. Deploy the backend (the prod Aliyun container restart) **with explicit user authorization** after Tasks 1-2 land. Until deployed, the desktop claim call 404s — Task 6 handles that gracefully (treat non-200 claim as "not won" so it never blocks, but you won't get the concurrency fix until deploy).

---

## Task 3: Desktop — Bilibili id extraction

**Files:**
- Modify: `client/src-tauri/src/core/ids.rs` (add fn + tests)

- [ ] **Step 1: Write the failing tests**

In `client/src-tauri/src/core/ids.rs`, inside `mod tests`, add:

```rust
    #[test]
    fn bilibili_bv_id() {
        assert_eq!(
            id_from_bilibili_url("https://www.bilibili.com/video/BV1xx411c7mu"),
            Some("BV1xx411c7mu".to_string())
        );
    }

    #[test]
    fn bilibili_bv_id_with_query() {
        assert_eq!(
            id_from_bilibili_url("https://www.bilibili.com/video/BV1GJ411x7h7?p=2&t=10"),
            Some("BV1GJ411x7h7".to_string())
        );
    }

    #[test]
    fn bilibili_short_link_has_no_bv() {
        // b23.tv short links don't carry the BV id → None → caller uses the
        // sha256 fallback (yt-dlp still resolves the redirect at download time).
        assert_eq!(id_from_bilibili_url("https://b23.tv/abc123"), None);
    }
```

- [ ] **Step 2: Run to verify failure**

Run (from `client/src-tauri`): `cargo test ids::`. Expected: FAIL — `cannot find function id_from_bilibili_url`.

- [ ] **Step 3: Implement**

In `client/src-tauri/src/core/ids.rs`, after `id_from_youtube_url` (closes line 28), add:

```rust
/// Extract the `BV…` id from a Bilibili URL. Bilibili's current scheme is "BV"
/// + 10 alphanumeric chars (12 total), e.g. BV1xx411c7mu. Returns None for URLs
/// without a BV id (e.g. b23.tv short links) so the caller can fall back to the
/// stable sha256 hash.
pub fn id_from_bilibili_url(url: &str) -> Option<String> {
    let idx = url.find("BV")?;
    let candidate: String = url[idx..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric())
        .collect();
    if candidate.len() == 12 {
        Some(candidate)
    } else {
        None
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cargo test ids::`. Expected: PASS (all ids tests, including the pre-existing `non_youtube_returns_none`).

- [ ] **Step 5: Commit**

```bash
git checkout -b feat/generic-url-import   # if not already on it (Get_Video repo)
git add client/src-tauri/src/core/ids.rs
git commit -m "feat(ids): id_from_bilibili_url (BV id extraction)"
```

---

## Task 4: Desktop — wire Bilibili into id resolution

**Files:**
- Modify: `client/src-tauri/src/commands/import.rs:97-98`

- [ ] **Step 1: Update the resolution chain**

In `client/src-tauri/src/commands/import.rs`, replace lines 97-98:

```rust
        "url" => ids::id_from_youtube_url(&req.source_value)
            .unwrap_or_else(|| ids::id_from_url_fallback(&req.source_value)),
```

with:

```rust
        "url" => ids::id_from_youtube_url(&req.source_value)
            .or_else(|| ids::id_from_bilibili_url(&req.source_value))
            .unwrap_or_else(|| ids::id_from_url_fallback(&req.source_value)),
```

- [ ] **Step 2: Build**

Run (from `client/src-tauri`): `cargo build`. Expected: compiles clean.

- [ ] **Step 3: Commit**

```bash
git add client/src-tauri/src/commands/import.rs
git commit -m "feat(import): resolve Bilibili BV ids (else sha256 fallback)"
```

---

## Task 5: Desktop — generic cloud sync (remove YouTube hard-coupling)

**Files:**
- Modify: `client/src-tauri/src/commands/library_sync.rs:75-76` and `:120`

This is the real B站 blocker: today sync calls `extract_youtube_id_rust(&source_url).ok_or("not_youtube")?` (rejects any non-YouTube URL) and hardcodes an `i.ytimg.com` thumbnail.

- [ ] **Step 1: Generalize the id derivation**

In `client/src-tauri/src/commands/library_sync.rs`, replace lines 75-76:

```rust
    let youtube_id = extract_youtube_id_rust(&source_url)
        .ok_or_else(|| "not_youtube".to_string())?;
```

with:

```rust
    // Generic: a real YouTube id when the source is YouTube (keeps the i.ytimg
    // cover + the iOS YouTube-embed fallback working); otherwise the entry's own
    // id (BV id / u_ hash). For non-YouTube the cover comes from thumbData (the
    // local ffmpeg thumb, built above) and playback from the OSS video below.
    let yt_id_opt = extract_youtube_id_rust(&source_url);
    let is_youtube = yt_id_opt.is_some();
    let youtube_id = yt_id_opt.unwrap_or_else(|| entry.id.clone());
```

- [ ] **Step 2: Make the thumbUrl conditional**

In the same file, replace line 120:

```rust
        "thumbUrl": format!("https://i.ytimg.com/vi/{youtube_id}/mqdefault.jpg"),
```

with:

```rust
        "thumbUrl": if is_youtube {
            serde_json::Value::String(format!("https://i.ytimg.com/vi/{youtube_id}/mqdefault.jpg"))
        } else {
            serde_json::Value::Null
        },
```

- [ ] **Step 3: Build**

Run (from `client/src-tauri`): `cargo build`. Expected: compiles clean.

- [ ] **Step 4: Commit**

```bash
git add client/src-tauri/src/commands/library_sync.rs
git commit -m "feat(library-sync): generic source id + thumb (allow non-YouTube sync)"
```

---

## Task 6: Desktop — atomic claim + friendly failure in the queue worker

**Files:**
- Modify: `client/src/lib/api/importQueue.ts` (add `claimItem`)
- Modify: `client/src/store/importQueue.ts:78-80` and `:137-145`

- [ ] **Step 1: Add the `claimItem` API client**

In `client/src/lib/api/importQueue.ts`, after `listPending` (ends line 94), add:

```ts
/**
 * Atomically claim a pending item. Returns true if THIS desktop won the claim,
 * false if another instance already took it (or the backend doesn't yet expose
 * the route — treated as "not won" so we never double-process; see caller).
 */
export async function claimItem(id: string): Promise<boolean> {
  const token = await getToken();
  const resp = await apiFetch(`${BASE}/${id}/claim`, { method: "POST", token });
  if (resp.status === 404) return false; // route not deployed yet → don't process
  if (!resp.ok) {
    const text = await resp.text().catch(() => "");
    throw new Error(`claimItem http ${resp.status}: ${text}`);
  }
  const body = (await resp.json()) as { claimed: boolean };
  return body.claimed;
}
```

- [ ] **Step 2: Use the claim in the worker**

In `client/src/store/importQueue.ts`, add to the imports (line 24):

```ts
import { listPending, setStatus, claimItem } from "../lib/api/importQueue";
```

Replace lines 79-80:

```ts
  // Mark as processing so other desktop instances (if any) don't double-pick.
  await setStatus(item.id, "processing");
```

with:

```ts
  // Atomically claim it; if another desktop already claimed it, skip this tick.
  const won = await claimItem(item.id);
  if (!won) {
    console.info(`[importQueue] item ${item.id} already claimed elsewhere, skipping`);
    return;
  }
```

- [ ] **Step 3: Friendly failure message**

In `client/src/store/importQueue.ts`, add this helper near the top (after the constants, before `processTick`):

```ts
/** Map a raw pipeline error to actionable Chinese copy for login-walled sites. */
function friendlyQueueError(raw: string): string {
  const t = raw.toLowerCase();
  if (
    raw.includes("登录") || raw.includes("会员") ||
    t.includes("login") || t.includes("cookies") || t.includes("account")
  ) {
    return `需要登录该网站后重试（桌面端 设置 → 登录对应站点 Cookie）。原始错误：${raw}`;
  }
  return raw;
}
```

Then in the catch block, replace lines 137-141:

```ts
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[importQueue] item ${item.id} failed:`, msg);
    try {
      await setStatus(item.id, "failed", msg);
```

with:

```ts
  } catch (err: unknown) {
    const raw = err instanceof Error ? err.message : String(err);
    const msg = friendlyQueueError(raw);
    console.error(`[importQueue] item ${item.id} failed:`, msg);
    try {
      await setStatus(item.id, "failed", msg);
```

(A `failed` item is never re-picked — `listPending` only returns `pending` — so there is no infinite-retry loop.)

- [ ] **Step 4: Typecheck**

Run (from `client`): `pnpm typecheck` (or `pnpm tsc --noEmit`). Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add client/src/lib/api/importQueue.ts client/src/store/importQueue.ts
git commit -m "feat(import-queue): atomic claim + friendly login-failure message"
```

---

## Task 7: iOS — VideoSource classifier

**Files:**
- Create: `whatsub-mobile/Networking/VideoSource.swift`
- Test: `whatsub-mobileTests/VideoSourceTests.swift`
- Modify: `project.yml` only if the test target doesn't already glob `whatsub-mobileTests/**` (check first; it likely does).

- [ ] **Step 1: Write the failing test**

Create `whatsub-mobileTests/VideoSourceTests.swift`:

```swift
import XCTest
@testable import whatsub_mobile

final class VideoSourceTests: XCTestCase {
    func testYouTubeHosts() {
        XCTAssertEqual(VideoSource.from(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(VideoSource.from(url: "https://youtu.be/dQw4w9WgXcQ"), .youtube)
    }
    func testBilibiliHosts() {
        XCTAssertEqual(VideoSource.from(url: "https://www.bilibili.com/video/BV1xx411c7mu"), .bilibili)
        XCTAssertEqual(VideoSource.from(url: "https://b23.tv/abc123"), .bilibili)
    }
    func testOtherAndGarbage() {
        XCTAssertEqual(VideoSource.from(url: "https://vimeo.com/12345"), .other)
        XCTAssertEqual(VideoSource.from(url: "not a url"), .other)
    }
    func testIsLikelyYouTubeId() {
        XCTAssertTrue(VideoSource.isLikelyYouTubeId("dQw4w9WgXcQ"))   // 11 chars
        XCTAssertFalse(VideoSource.isLikelyYouTubeId("BV1xx411c7mu")) // 12, BV
        XCTAssertFalse(VideoSource.isLikelyYouTubeId("u_0123456789")) // fallback hash
    }
}
```

- [ ] **Step 2: Note on running**

iOS can't build on Windows. This test runs in CI on push (Task 11). For now it should "fail" only in the sense that `VideoSource` doesn't exist yet — proceed to Step 3.

- [ ] **Step 3: Create `VideoSource.swift`**

```swift
import Foundation

/// Which platform a library/import URL belongs to. Drives import routing
/// (YouTube has a client-side caption path; everything else → desktop queue)
/// and the playback fallback guard.
enum VideoSource {
    case youtube
    case bilibili
    case other

    /// Classify by URL host.
    static func from(url: String) -> VideoSource {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return .other }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("bilibili.com") || host.contains("b23.tv") { return .bilibili }
        return .other
    }

    /// A real YouTube video id is exactly 11 chars of [A-Za-z0-9_-]. Bilibili BV
    /// ids (12 chars, "BV…") and fallback hashes ("u_…") fail this — so we never
    /// feed a non-YouTube id to the YouTube embed.
    static func isLikelyYouTubeId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
```

- [ ] **Step 4: Commit (LOCAL only — do not push)**

```bash
git add whatsub-mobile/Networking/VideoSource.swift whatsub-mobileTests/VideoSourceTests.swift
git commit -m "feat(ios): VideoSource classifier + YouTube-id-shape check"
```

---

## Task 8: iOS — route non-YouTube URLs to the desktop queue

**Files:**
- Modify: `whatsub-mobile/Import/ImportViewModel.swift:6-19` (add state) and `:35-50` (routing)

- [ ] **Step 1: Add the `.needsDesktop` state**

In `ImportViewModel.swift`, in the `State` enum (lines 6-19), after `case pushedToDesktop` add:

```swift
        /// A non-YouTube source (Bilibili / other) that has no client-side
        /// caption path — offer to push it to the desktop queue.
        case needsDesktop(message: String)
```

- [ ] **Step 2: Route at the top of `run`**

In `ImportViewModel.swift`, at the start of `run(urlOrId:)` (after computing `trimmed`, line 36), insert before the YouTube-id resolution:

```swift
        // Non-YouTube URLs have no phone-side caption path (Bilibili CC is
        // Chinese/absent). Route straight to the desktop queue. A bare 11-char
        // YouTube id has no "://" → falls through to the YouTube path below.
        if trimmed.contains("://"), VideoSource.from(url: trimmed) != .youtube {
            resolvedSourceURL = trimmed
            videoId = ""
            title = trimmed
            state = .needsDesktop(message: "B站 / 其它来源无法在手机端取字幕，可推送到桌面端用 whisper 转录 + 解析（需桌面在线且登录同一账号）。")
            return
        }
```

(The existing YouTube resolution + extraction + analysis below is unchanged. `pushToDesktop(token:)` already uses `resolvedSourceURL`, so the push works as-is.)

- [ ] **Step 3: Commit (LOCAL only)**

```bash
git add whatsub-mobile/Import/ImportViewModel.swift
git commit -m "feat(ios/import): route non-YouTube URLs to desktop queue"
```

---

## Task 9: iOS — render `.needsDesktop` + update idle copy

**Files:**
- Modify: `whatsub-mobile/Import/ImportView.swift:46-52` (switch), `:73-81` (idle copy), `:222-270` (generalize the push-offer body)

- [ ] **Step 1: Generalize `extractFailedBody` → `pushOfferBody(title:message:)`**

In `ImportView.swift`, change the function signature (line 222) from:

```swift
    private func extractFailedBody(_ message: String) -> some View {
```

to:

```swift
    private func pushOfferBody(title: String, message: String) -> some View {
```

and inside it, change the header `Text("未找到字幕")` (line 230) to:

```swift
            Text(title)
```

- [ ] **Step 2: Update the switch to use it + add the new case**

In `ImportView.swift`, in the `switch vm.state` (lines 46-51), replace:

```swift
            case .extractFailed(let msg):
                extractFailedBody(msg)
```

with:

```swift
            case .extractFailed(let msg):
                pushOfferBody(title: "未找到字幕", message: msg)
            case .needsDesktop(let msg):
                pushOfferBody(title: "需在桌面端处理", message: msg)
```

- [ ] **Step 3: Update idle copy for multi-source**

In `idleBody` (lines 73-84), replace:

```swift
            Text("粘贴 YouTube 链接或 Video ID")
                .font(.headline)
                .foregroundStyle(.whatsubInk)

            Text("解析需挂 VPN 连接 YouTube")
                .font(.caption)
                .foregroundStyle(.whatsubInkMuted)

            TextField("https://youtube.com/watch?v=… 或 11 位 ID", text: $urlInput)
```

with:

```swift
            Text("粘贴 YouTube / B站 / 其它视频链接")
                .font(.headline)
                .foregroundStyle(.whatsubInk)

            Text("YouTube 有字幕在手机端解析（需挂 VPN）；B站 / 其它将推送到桌面端用 whisper 处理")
                .font(.caption)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)

            TextField("https://… 或 YouTube 11 位 ID", text: $urlInput)
```

- [ ] **Step 4: Commit (LOCAL only)**

```bash
git add whatsub-mobile/Import/ImportView.swift
git commit -m "feat(ios/import): needsDesktop screen + multi-source idle copy"
```

---

## Task 10: iOS — playback guard (never embed a non-YouTube id)

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift:45-77`

- [ ] **Step 1: Add a desktop-only helper + placeholder**

In `LibraryDetailView.swift`, add near `player(_:fullscreen:)` (e.g. after `playerOverlay`, before `portrait`):

```swift
    /// True when there is no OSS video AND the id isn't a real YouTube id —
    /// i.e. a queue import whose video isn't on OSS (still processing / failed).
    private func isDesktopOnly(_ entry: LibraryEntryDetail) -> Bool {
        entry.videoUrl == nil && !VideoSource.isLikelyYouTubeId(entry.youtubeId)
    }

    private var desktopOnlyPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.title)
                .foregroundStyle(.whatsubInkMuted)
            Text("此视频需在桌面端查看")
                .font(.callout)
                .foregroundStyle(.whatsubInk)
            Text("云端尚无可播放的视频文件（可能仍在桌面端处理）。")
                .font(.caption)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

- [ ] **Step 2: Update the `player` branches + overlay gate**

In `LibraryDetailView.swift`, replace the body of `player(_:fullscreen:)` (lines 46-71) with:

```swift
        ZStack {
            if let v = entry.videoUrl, let url = URL(string: v) {
                VideoPlayerView(
                    url: url,
                    seek: vm.seek,
                    onReady: { playerReady = true },
                    onTime: { sec in vm.onPlayerTime(sec) }
                )
            } else if VideoSource.isLikelyYouTubeId(entry.youtubeId) {
                YouTubeEmbedView(
                    videoId: entry.youtubeId,
                    seek: vm.seek,
                    onReady: { playerReady = true },
                    onTime: { sec in vm.onPlayerTime(sec) }
                )
            } else {
                desktopOnlyPlaceholder
            }
            if !playerReady && !isDesktopOnly(entry) { playerOverlay(isYouTube: entry.videoUrl == nil) }
            if playerReady {
                VStack {
                    HStack { Spacer(); captionToggle }
                    Spacer()
                    if showCaptions, let cue = vm.currentCue { captionBar(cue) }
                }
                .padding(fullscreen ? 16 : 8)
            }
        }
```

(The `.background(Color.black)` + `.task { 15s timeout }` after line 71 stay unchanged. For the desktop-only placeholder, `playerReady` never flips and the overlay is suppressed, so it shows the static placeholder.)

- [ ] **Step 3: Commit (LOCAL only)**

```bash
git add whatsub-mobile/Library/LibraryDetailView.swift
git commit -m "feat(ios/library): playback guard — desktop-only placeholder for non-YouTube w/o OSS video"
```

---

## Task 11: Integration — deploy backend, verify desktop end-to-end, push iOS

This task ties the repos together and is mostly manual verification (no unit test can cover the live yt-dlp + OSS + cross-device flow).

- [ ] **Step 1: Deploy backend (with user authorization)**

After Tasks 1-2 are committed, get explicit user authorization, then deploy `whatsub-license` to prod (push `feat/generic-url-import` → merge to main per the repo's flow → restart the Aliyun container). Verify the route is live:

```bash
# Expect 401 (auth required) NOT 404 (route missing):
curl -s -o /dev/null -w "%{http_code}" -X POST https://whatsub.eversay.cc/api/library/import-queue/x/claim
```
Expected: `401`.

- [ ] **Step 2: Build + run the desktop locally**

From `Get_Video/client`: `pnpm tauri dev`. Log in with the same account as the phone. Ensure a whisper model is configured (Settings) and, if testing a login-walled Bilibili video, that Bilibili cookies are logged in on the desktop.

- [ ] **Step 3: Enqueue a Bilibili URL from the phone path (or curl)**

Either via the iOS app once pushed, or simulate the phone push directly:

```bash
TOKEN=...   # a valid session token for the test account
curl -s -X POST https://whatsub.eversay.cc/api/library/import-queue \
  -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"url":"https://www.bilibili.com/video/BV1xx411c7mu"}'
```
Expected: `{"id":"…"}`.

- [ ] **Step 4: Verify the desktop processes it**

Watch the desktop console for `[importQueue] processing item …` → `import_video done` → `syncing … to cloud` → `item … done`. Then confirm:
- The video appears in the desktop Library grid (orphan-reconcile already handles this).
- In the iOS Library list it appears with a cover (from thumbData) and plays via AVPlayer with **no VPN**.

- [ ] **Step 5: Verify concurrency (optional but recommended)**

With the route deployed, run two desktop instances (or call `/claim` twice via curl on the same pending id): exactly one returns `{"claimed":true}`, the other `{"claimed":false}`; only one download happens.

- [ ] **Step 6: Push iOS (single TestFlight trigger)**

Only now push the iOS branch. This is the ONE push that triggers CI + TestFlight (burns one Apple cert slot — see CLAUDE.md gotcha). Bundle everything:

```bash
# whatsub-mobile, on feat/generic-url-import (spec + all iOS commits already local)
git push -u origin feat/generic-url-import
gh pr create --title "Generic URL import (queue path) — Bilibili first source" --body "..."
```
Verify the CI run is green (`VideoSourceTests` pass) before merging to main. If TestFlight Archive fails with "maximum number of certificates", revoke old certs at developer.apple.com → Certificates, then `gh run rerun <run-id>`.

- [ ] **Step 7: Update docs (bundle, no extra TestFlight trigger)**

Update each repo's CLAUDE.md for the new generic-import path (whatsub-license: claim endpoint; Get_Video: generic id/sync + atomic claim; whatsub-mobile: multi-source import + playback guard). Commit on the same branches so they ride the existing pushes.

---

## Self-Review

**1. Spec coverage:**
- Atomic claim (spec §"Atomic claim 方案A") → Tasks 1, 2, 6. ✓
- Generic id / remove not_youtube + i.ytimg (spec §Desktop) → Tasks 3, 4, 5. ✓
- iOS source classify + route + skip caption extraction (spec §iOS) → Tasks 7, 8. ✓
- iOS playback guard / never embed non-YouTube (spec §iOS, decision 6) → Task 10. ✓
- Import field copy (spec §iOS) → Task 9. ✓
- Cookies/login desktop-side (spec decision 2) → no code (desktop already multi-site); failure message → Task 6 Step 3. ✓
- Failure handling v1 desktop-side (decision 3) → Task 6 (friendly message, no infinite retry; failed not re-picked). ✓
- No schema migration (decision 5) → confirmed: source derived (Task 5 uses entry.id; iOS uses id-shape). ✓
- Share Extension accepts any URL → verified in recon (ShareViewController loads any `public.url`, no change needed). ✓
- Fast-follows (phone failure surfacing, stale reclaim, backend worker, Bilibili embed) → intentionally NOT tasked. ✓

**2. Placeholder scan:** No "TBD/handle errors/similar to". Every code step shows the actual diff. The only `...` is in the `gh pr create --body "..."` (a free-text PR body, not code) and a `TOKEN=...` placeholder for a secret the operator fills — both legitimate.

**3. Type consistency:**
- `claimImportItem(id, ownerEmail, now): Promise<boolean>` — defined Task 1, called by route Task 2 (same args), called via `claimItem(id)` HTTP wrapper Task 6. ✓
- `id_from_bilibili_url(&str) -> Option<String>` — defined Task 3, called Task 4. ✓
- `VideoSource.from(url:) -> VideoSource` + `isLikelyYouTubeId(_:) -> Bool` — defined Task 7, used Tasks 8 (`from`) + 10 (`isLikelyYouTubeId`). ✓
- `.needsDesktop(message:)` — added Task 8, rendered Task 9. ✓
- `pushOfferBody(title:message:)` — renamed Task 9; both `.extractFailed` and `.needsDesktop` call it. ✓
- `is_youtube` / `youtube_id` (Task 5) used consistently in the same file's payload. ✓

No gaps found.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-23-generic-url-import.md`. Two execution options:

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration. Backend (1-2) → Desktop (3-6) → iOS (7-10), then the integration/deploy/push task (11) done interactively with you (it needs your authorization for the prod deploy + the single TestFlight push).

**2. Inline Execution** — execute tasks in this session with checkpoints.

Which approach?
