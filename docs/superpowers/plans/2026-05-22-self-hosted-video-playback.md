# Self-Hosted Video Playback (OSS + CDN + native AVPlayer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** Library videos play from the user's Aliyun OSS via CDN with a native iOS AVPlayer (China-reachable, instant seek), replacing the VPN-only laggy YouTube embed. Falls back to YouTube embed for entries without an uploaded video.

**Architecture:** Desktop transcodes `source.mp4`→720p, requests a backend presigned PUT, uploads straight to OSS, and reports the `videoKey` on sync. Backend stores `video_key`, signs a CDN `auth_key` URL (2h TTL) into `/list`+`/entry`. iOS plays `videoUrl` via AVPlayer when present.

**Tech Stack:** Hono + node-postgres + `ali-oss` (backend) · Rust + ffmpeg sidecar + reqwest (desktop) · SwiftUI + AVKit (iOS).

**Spec:** `docs/superpowers/specs/2026-05-22-self-hosted-video-playback-design.md`.

**Reference (user's existing OSS+CDN code):** `C:\Users\renjx\Desktop\Enghub\apps\api\src\common\storage\oss-storage.service.ts` — `createPresignedPutUrl` (signatureUrl PUT) + `signUrl` (CDN A-type `auth_key` MD5). Reuse the Enghub bucket + CDN domain (env values supplied by the user on the server).

---

## File Structure

**Backend (`whatsub-license`)** — branch `feat/video-oss`
| File | Change |
|---|---|
| `package.json` | + `ali-oss` dep |
| `src/lib/oss.ts` | NEW — `createPresignedPutUrl`, `signCdnUrl`, `ossConfigured` |
| `schema.sql` | + `video_key TEXT` |
| `src/lib/types.ts` | `SyncLibraryEntryInput` + `videoKey?` |
| `src/lib/db.ts` | upsert stores `video_key`; list/entry add signed `videoUrl` |
| `src/routes/library.ts` | + `POST /upload-url`; `/sync` accepts `videoKey` |
| `tests/library-routes.test.ts` | + upload-url + videoUrl tests |
| `tests/oss.test.ts` | NEW — signCdnUrl determinism |

**Desktop (`Get_Video/client`)** — branch `feat/desktop-video-upload`
| File | Change |
|---|---|
| `src-tauri/src/pipeline/ffmpeg.rs` | + `transcode_720p` helper |
| `src-tauri/src/commands/library_sync.rs` | transcode → upload-url → PUT → `videoKey` in sync |

**iOS (`whatsub-mobile`)** — branch `feat/ios-avplayer`
| File | Change |
|---|---|
| `whatsub-mobile/Components/VideoPlayerView.swift` | NEW — AVPlayer wrapper |
| `whatsub-mobile/Networking/DTOs.swift` | `LibraryEntryDetail` + `videoUrl` |
| `whatsub-mobile/Library/LibraryDetailView.swift` | play AVPlayer when videoUrl else YouTube |

---

## PART A — Backend (`whatsub-license`)

### Pre-flight
```bash
cd /c/Users/renjx/Desktop/whatsub-license
git checkout main && git pull && git checkout -b feat/video-oss
pnpm install && pnpm test --run 2>&1 | tail -3   # baseline green (~313)
```

### Task A1: ali-oss dep + oss.ts

**Files:** `package.json`, create `src/lib/oss.ts`

- [ ] **Step 1:** `pnpm add ali-oss && pnpm add -D @types/ali-oss`
- [ ] **Step 2:** Create `src/lib/oss.ts`:
```typescript
import OSS from 'ali-oss';
import { createHash, randomUUID } from 'crypto';

const URL_TTL = 2 * 60 * 60; // CDN signed-URL validity: 2h
const PUT_TTL = 15 * 60;     // presigned upload window: 15 min

let _client: OSS | null = null;
function client(): OSS {
  if (!_client) {
    _client = new OSS({
      region: process.env.OSS_REGION || 'oss-cn-beijing',
      accessKeyId: process.env.OSS_ACCESS_KEY_ID!,
      accessKeySecret: process.env.OSS_ACCESS_KEY_SECRET!,
      bucket: process.env.OSS_BUCKET!,
      secure: true, // public HTTPS endpoint — the desktop uploads over the internet
    });
  }
  return _client;
}

/** True when all OSS+CDN env vars are present. Routes 503 when false so the
 *  feature degrades gracefully (entry falls back to the YouTube embed). */
export function ossConfigured(): boolean {
  return !!(
    process.env.OSS_ACCESS_KEY_ID &&
    process.env.OSS_ACCESS_KEY_SECRET &&
    process.env.OSS_BUCKET &&
    process.env.CDN_BASE_URL &&
    process.env.CDN_AUTH_KEY
  );
}

/** Presigned PUT URL (public OSS endpoint) for direct client upload. The
 *  uploader MUST send the same Content-Type header or the signature mismatches. */
export async function createPresignedPutUrl(objectKey: string, contentType: string): Promise<string> {
  return client().signatureUrl(objectKey, {
    method: 'PUT',
    expires: PUT_TTL,
    'Content-Type': contentType,
  });
}

/** Signed CDN URL (Aliyun A-type auth_key) — China-reachable, 2h TTL. Pure
 *  crypto, no OSS client needed (testable without credentials). Mirror of the
 *  Enghub OssStorageService.signUrl. */
export function signCdnUrl(objectKey: string): string {
  const base = process.env.CDN_BASE_URL!;
  const authKey = process.env.CDN_AUTH_KEY!;
  const uri = `/${objectKey}`;
  const timestamp = Math.floor(Date.now() / 1000) + URL_TTL;
  const rand = randomUUID().replace(/-/g, '').slice(0, 16);
  const uid = '0';
  const md5 = createHash('md5').update(`${uri}-${timestamp}-${rand}-${uid}-${authKey}`).digest('hex');
  return `${base}${uri}?auth_key=${timestamp}-${rand}-${uid}-${md5}`;
}

/** Deterministic per-owner object key. Re-sync overwrites the same object. */
export function videoKeyFor(email: string, id: string): string {
  const ownerHash = createHash('sha256').update(email).digest('hex').slice(0, 16);
  return `whatsub/library/${ownerHash}/${id}.mp4`;
}
```
- [ ] **Step 3:** Commit: `git add package.json pnpm-lock.yaml src/lib/oss.ts && git commit -m "feat(library/video): ali-oss signer (presigned PUT + CDN auth_key)"`

### Task A2: signCdnUrl test (TDD-ish)

**Files:** create `tests/oss.test.ts`

- [ ] **Step 1:** Write test:
```typescript
import { describe, it, expect, beforeAll } from 'vitest';
import { createHash } from 'crypto';
import { signCdnUrl, videoKeyFor } from '../src/lib/oss.js';

describe('signCdnUrl', () => {
  beforeAll(() => {
    process.env.CDN_BASE_URL = 'https://cdn.example.com';
    process.env.CDN_AUTH_KEY = 'testsecret';
  });
  it('produces a valid Aliyun A-type auth_key URL', () => {
    const key = 'whatsub/library/abc123/vid.mp4';
    const url = signCdnUrl(key);
    expect(url.startsWith('https://cdn.example.com/whatsub/library/abc123/vid.mp4?auth_key=')).toBe(true);
    const authKey = new URL(url).searchParams.get('auth_key')!;
    const [ts, rand, uid, md5] = authKey.split('-');
    expect(uid).toBe('0');
    expect(rand).toHaveLength(16);
    const expected = createHash('md5')
      .update(`/${key}-${ts}-${rand}-${uid}-testsecret`).digest('hex');
    expect(md5).toBe(expected);
  });
  it('videoKeyFor is deterministic + namespaced', () => {
    const a = videoKeyFor('x@y.com', 'vid');
    expect(a).toBe(videoKeyFor('x@y.com', 'vid'));
    expect(a).toMatch(/^whatsub\/library\/[0-9a-f]{16}\/vid\.mp4$/);
  });
});
```
- [ ] **Step 2:** `pnpm test tests/oss.test.ts --run` → PASS.
- [ ] **Step 3:** Commit: `git add tests/oss.test.ts && git commit -m "test(library/video): signCdnUrl + videoKeyFor"`

### Task A3: schema + db (video_key + videoUrl)

**Files:** `schema.sql`, `src/lib/types.ts`, `src/lib/db.ts`

- [ ] **Step 1:** `schema.sql` — after the existing `thumb_data` ALTER:
```sql
ALTER TABLE library_entries ADD COLUMN IF NOT EXISTS video_key TEXT;
```
Verify pg-mem parses (same one-liner as other schema tasks).
- [ ] **Step 2:** `types.ts` — add to `SyncLibraryEntryInput`: `videoKey?: string;`
- [ ] **Step 3:** `db.ts` `upsertLibraryEntry` — add `video_key` as `$12`:
  - column list: append `, video_key`
  - VALUES: append `, $12`
  - ON CONFLICT SET: append `, video_key = EXCLUDED.video_key`
  - params array: append `input.videoKey ?? null,`
- [ ] **Step 4:** `db.ts` `listLibraryEntriesForOwner` + `getLibraryEntry` — SELECT `video_key`, and in the JS mapping add a signed `videoUrl` when present:
```typescript
import { signCdnUrl } from './oss.js'; // top of db.ts
// in each mapped row:
videoUrl: r.video_key ? signCdnUrl(r.video_key) : null,
```
(Add `video_key` to the SELECT column lists. `listLibraryEntriesForOwner` already selects has_thumb; add `video_key` there too. `getLibraryEntry` likewise.)
- [ ] **Step 5:** `pnpm typecheck` → clean.
- [ ] **Step 6:** Commit: `git add schema.sql src/lib/types.ts src/lib/db.ts && git commit -m "feat(library/video): video_key column + signed videoUrl in list/entry"`

### Task A4: routes — POST /upload-url + sync videoKey (TDD)

**Files:** `tests/library-routes.test.ts`, `src/routes/library.ts`

- [ ] **Step 1:** Failing tests (append to library-routes.test.ts). Set CDN env in the file's setup so signCdnUrl works:
```typescript
describe('video upload-url + videoUrl', () => {
  beforeAll(() => {
    process.env.CDN_BASE_URL = 'https://cdn.example.com';
    process.env.CDN_AUTH_KEY = 'testsecret';
    process.env.OSS_ACCESS_KEY_ID = 'x';
    process.env.OSS_ACCESS_KEY_SECRET = 'y';
    process.env.OSS_BUCKET = 'b';
  });

  it('sync stores videoKey → list/entry expose a signed videoUrl', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    const r = await rig.app.request('/api/library/sync', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'vk1', videoKey: 'whatsub/library/abc/vk1.mp4' }),
    });
    expect(r.status).toBe(200);
    const list = await (await rig.app.request('/api/library/list', { headers: { authorization: `Bearer ${token}` } })).json() as any;
    const row = list.entries.find((e: any) => e.id === 'vk1');
    expect(row.videoUrl).toContain('https://cdn.example.com/whatsub/library/abc/vk1.mp4?auth_key=');
    const entry = await (await rig.app.request('/api/library/entry/vk1', { headers: { authorization: `Bearer ${token}` } })).json() as any;
    expect(entry.videoUrl).toContain('auth_key=');
  });

  it('entry without videoKey has videoUrl null', async () => {
    const rig = makeApp();
    const token = await insertSessionFor(rig.db, 'alice@example.com');
    await rig.app.request('/api/library/sync', {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...VALID_BODY, id: 'novk' }),
    });
    const entry = await (await rig.app.request('/api/library/entry/novk', { headers: { authorization: `Bearer ${token}` } })).json() as any;
    expect(entry.videoUrl).toBeNull();
  });
});
```
(NOTE: `POST /upload-url` calls the real ali-oss `signatureUrl`, which needs a network-free crypto signing — ali-oss `signatureUrl` is synchronous crypto, no network, so it works in tests with dummy creds. If it throws in pg-mem/test env, wrap the upload-url route assertion in its own test that just checks the response shape `{putUrl, videoKey}` and that putUrl contains the bucket+key. If ali-oss signatureUrl misbehaves without a real region, assert only `videoKey` + status 200.)
- [ ] **Step 2:** Run → RED.
- [ ] **Step 3:** `src/routes/library.ts` — add the upload-url route (session-gated) + accept videoKey in /sync:
```typescript
import { createPresignedPutUrl, ossConfigured, videoKeyFor } from '../lib/oss.js';

  app.post('/upload-url', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    let body: Record<string, unknown>;
    try { body = (await c.req.json()) as Record<string, unknown>; }
    catch { return c.json({ error: 'invalid_json' }, 400); }
    const id = typeof body.id === 'string' ? body.id.trim() : '';
    const contentType = typeof body.contentType === 'string' ? body.contentType : 'video/mp4';
    if (!id) return c.json({ error: 'invalid_input' }, 400);
    if (!ossConfigured()) return c.json({ error: 'oss_not_configured' }, 503);
    const videoKey = videoKeyFor(email, id);
    const putUrl = await createPresignedPutUrl(videoKey, contentType);
    return c.json({ putUrl, videoKey });
  });
```
In `POST /sync`, after `const thumbData = ...`, add:
```typescript
    const videoKey = typeof body.videoKey === 'string' ? body.videoKey : undefined;
```
and pass `videoKey` into `db.upsertLibraryEntry({ ..., videoKey })`.
- [ ] **Step 4:** Run → GREEN. `pnpm typecheck && pnpm test --run 2>&1 | tail -4`.
- [ ] **Step 5:** Commit: `git add src/routes/library.ts tests/library-routes.test.ts && git commit -m "feat(library/video): POST /upload-url + sync accepts videoKey"`

### Task A5: Update API.md
- [ ] Document `POST /api/library/upload-url` (session → `{putUrl, videoKey}`, 503 `oss_not_configured`) + the `videoKey` field on `/sync` + `videoUrl` on list/entry. Commit.

### Task A6: Deploy — PAUSE for user

**STOP. Get user authorization. The user must FIRST add OSS+CDN env to `/opt/whatsub/.env` (reuse Enghub values — secrets never read into chat).**

- [ ] **Step 1:** User adds to `/opt/whatsub/.env`: `OSS_REGION, OSS_ACCESS_KEY_ID, OSS_ACCESS_KEY_SECRET, OSS_BUCKET, CDN_BASE_URL, CDN_AUTH_KEY`. Confirm present:
```bash
ssh … "grep -c '^OSS_ACCESS_KEY_ID=\|^CDN_AUTH_KEY=' /opt/whatsub/.env"   # expect 2
```
- [ ] **Step 2:** Merge to main; apply schema (idempotent ALTER, scp + psql); build + ship + `docker compose up -d --force-recreate whatsub-license` (standard deploy from earlier plans).
- [ ] **Step 3:** Smoke (needs a temp session token like prior tasks): `POST /api/library/upload-url {id:"smoke"}` → 200 `{putUrl, videoKey}` where putUrl contains the bucket host + `whatsub/library/.../smoke.mp4`. Revoke the temp token.

---

## PART B — Desktop (`Get_Video/client`)

### Pre-flight
```bash
cd /c/Users/renjx/Desktop/Get_Video/client
git checkout main && git pull && git checkout -b feat/desktop-video-upload
```

### Task B1: ffmpeg transcode_720p

**Files:** `src-tauri/src/pipeline/ffmpeg.rs`

- [ ] **Step 1:** Add after `downscale_jpeg`:
```rust
/// Transcode a video to a mobile-friendly 720p H.264 MP4 (never upscales) with
/// faststart (moov atom up front for progressive streaming). Used by library
/// cloud-sync before uploading to OSS.
pub async fn transcode_720p(
    app: &AppHandle,
    src_path: &Path,
    out_path: &Path,
    video_id: &str,
    cancel: Option<&CancellationToken>,
) -> AppResult<()> {
    let src = src_path.to_string_lossy().to_string();
    let out = out_path.to_string_lossy().to_string();
    let log = make_log_emitter(app, video_id);
    run_sidecar(
        app,
        "ffmpeg",
        &[
            "-y", "-i", &src,
            "-vf", "scale=-2:'min(720,ih)'",
            "-c:v", "libx264", "-crf", "23", "-preset", "veryfast",
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            &out,
        ],
        log,
        cancel,
    )
    .await?;
    Ok(())
}
```
- [ ] **Step 2:** `cargo build --quiet` → clean. Commit: `git add src-tauri/src/pipeline/ffmpeg.rs && git commit -m "feat(video): ffmpeg transcode_720p helper"`

### Task B2: upload video in library_sync

**Files:** `src-tauri/src/commands/library_sync.rs`

- [ ] **Step 1:** After the `thumb_b64` block and BEFORE building `body`, add the transcode+upload (best-effort → `video_key: Option<String>`):
```rust
    // Transcode source.mp4 → 720p mobile.mp4, request a presigned PUT, upload
    // direct to OSS. Best-effort: any failure → no videoKey → iOS falls back to
    // the YouTube embed for this entry.
    let video_key: Option<String> = async {
        let src = std::path::Path::new(video_dir).join("source.mp4");
        if !src.exists() { return None; }
        let mobile = std::path::Path::new(video_dir).join("mobile.mp4");
        crate::pipeline::ffmpeg::transcode_720p(&app, &src, &mobile, &id, None).await.ok()?;

        // 1. ask backend for a presigned PUT
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(NET_TIMEOUT_SECS))
            .build().ok()?;
        #[derive(serde::Deserialize)]
        struct UploadUrl { #[serde(rename = "putUrl")] put_url: String, #[serde(rename = "videoKey")] video_key: String }
        let uu: UploadUrl = client
            .post(format!("{API_BASE}/upload-url"))
            .header("content-type", "application/json")
            .header("authorization", format!("Bearer {}", auth_state.session_token))
            .body(serde_json::json!({ "id": entry.id, "contentType": "video/mp4" }).to_string())
            .send().await.ok()?
            .error_for_status().ok()?
            .json().await.ok()?;

        // 2. PUT the file straight to OSS (Content-Type MUST match the signature)
        let bytes = std::fs::read(&mobile).ok()?;
        let put = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(NET_TIMEOUT_SECS * 4)) // larger payload
            .build().ok()?
            .put(&uu.put_url)
            .header("content-type", "video/mp4")
            .body(bytes)
            .send().await.ok()?;
        if !put.status().is_success() { return None; }
        let _ = std::fs::remove_file(&mobile);
        Some(uu.video_key)
    }.await;
```
(NOTE: `video_dir`, `id`, `app`, `auth_state`, `API_BASE`, `NET_TIMEOUT_SECS` are all already in scope in `library_sync_to_cloud`. Verify the `async {}.await` block compiles; if the closure-capture is awkward, inline it as sequential `let` statements with early `None` via a helper fn instead.)
- [ ] **Step 2:** Add `"videoKey": video_key,` to the `serde_json::json!({...})` POST body.
- [ ] **Step 3:** `cargo build --quiet` → clean; `cargo test --quiet` → green. Commit: `git add src-tauri/src/commands/library_sync.rs && git commit -m "feat(video): transcode + upload mobile.mp4 to OSS in library_sync"`

---

## PART C — iOS (`whatsub-mobile`)

### Pre-flight
```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git checkout main && git pull && git checkout -b feat/ios-avplayer
```

### Task C1: VideoPlayerView (AVPlayer)

**Files:** create `whatsub-mobile/Components/VideoPlayerView.swift`

- [ ] **Step 1:**
```swift
import SwiftUI
import AVKit

/// Native AVPlayer-backed video view. Input surface mirrors YouTubeEmbedView
/// (url, seek, onReady, onTime) so LibraryDetailView can swap between them
/// without changing the view model.
struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    var seek: SeekRequest?
    var onReady: () -> Void
    var onTime: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onTime: onTime) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = true
        let vc = AVPlayerViewController()
        vc.player = player
        vc.videoGravity = .resizeAspect
        vc.showsPlaybackControls = true
        context.coordinator.attach(player: player)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        guard let seek, seek != context.coordinator.lastSeek else { return }
        context.coordinator.lastSeek = seek
        let t = CMTime(seconds: seek.seconds, preferredTimescale: 600)
        vc.player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        vc.player?.play()
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        let onReady: () -> Void
        let onTime: (Double) -> Void
        var lastSeek: SeekRequest?
        private weak var player: AVPlayer?
        private var timeObserver: Any?
        private var statusObs: NSKeyValueObservation?
        private var didReady = false

        init(onReady: @escaping () -> Void, onTime: @escaping (Double) -> Void) {
            self.onReady = onReady; self.onTime = onTime
        }
        func attach(player: AVPlayer) {
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] t in self?.onTime(t.seconds) }
            statusObs = player.observe(\.status, options: [.new]) { [weak self] p, _ in
                guard let self, !self.didReady, p.status == .readyToPlay else { return }
                self.didReady = true; self.onReady()
            }
        }
        func detach() {
            if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
            statusObs?.invalidate(); statusObs = nil
        }
        deinit { detach() }
    }
}
```
- [ ] **Step 2:** Commit: `git add whatsub-mobile/Components/VideoPlayerView.swift && git commit -m "feat(ios/video): native AVPlayer VideoPlayerView"`

### Task C2: DTO videoUrl

**Files:** `whatsub-mobile/Networking/DTOs.swift`

- [ ] **Step 1:** Add `let videoUrl: String?` to `LibraryEntryDetail` (it's a synthesized Decodable; the backend returns `videoUrl` or null). Place it after `analysisJson`. Verify nothing else needs CodingKeys (camelCase matches).
- [ ] **Step 2:** Commit: `git add whatsub-mobile/Networking/DTOs.swift && git commit -m "feat(ios/video): LibraryEntryDetail.videoUrl"`

### Task C3: LibraryDetailView player swap

**Files:** `whatsub-mobile/Library/LibraryDetailView.swift`

- [ ] **Step 1:** Replace the `player(_:)` function so it picks the native player when `videoUrl` is present, else the YouTube embed. Keep the loading overlay + 15s timeout wrapping BOTH (both call `onReady`/`onTime`/`seek`):
```swift
    private func player(_ entry: LibraryEntryDetail) -> some View {
        ZStack {
            if let v = entry.videoUrl, let url = URL(string: v) {
                VideoPlayerView(
                    url: url,
                    seek: vm.seek,
                    onReady: { playerReady = true },
                    onTime: { sec in vm.onPlayerTime(sec) }
                )
            } else {
                YouTubeEmbedView(
                    videoId: entry.youtubeId,
                    seek: vm.seek,
                    onReady: { playerReady = true },
                    onTime: { sec in vm.onPlayerTime(sec) }
                )
            }
            if !playerReady { playerOverlay }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .background(Color.black)
        .task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !playerReady { playerTimedOut = true }
        }
    }
```
(`playerOverlay`'s VPN-hint copy still applies to the YouTube fallback; for the AVPlayer path it just shows a brief spinner until `readyToPlay`. Optionally tweak the overlay text to be source-aware — not required for v1.)
- [ ] **Step 2:** Commit: `git add whatsub-mobile/Library/LibraryDetailView.swift && git commit -m "feat(ios/video): play AVPlayer when videoUrl present, else YouTube"`

### Task C4: Push branch + CI
- [ ] Push `feat/ios-avplayer`; watch CI (`gh run watch …`). Watch-outs: `import AVKit`, `CMTime` usage, AVPlayerViewController in a `.fit` aspect frame. Fix + re-push until green.

### Task C5: Merge + TestFlight — PAUSE for user
- [ ] **STOP. Get authorization** (TestFlight + cert slots). Merge → main; watch testflight.yml.

---

## End-to-end verification (after all parts deployed)
1. Desktop: re-sync a video → console shows transcode + upload; backend `video_key` populated.
2. `curl` (temp token) `GET /api/library/entry/<id>` → `videoUrl` is a `cdn…?auth_key=` URL; `curl -I` that URL → 200 + `Content-Type: video/mp4` + `Accept-Ranges: bytes`.
3. iOS (NO VPN): open that video → native AVPlayer plays; tap subtitle cues → seeks instantly; subtitle follow works. Old (un-uploaded) entries still show the YouTube embed.

## Done criteria
- Synced videos play via native AVPlayer from OSS+CDN without VPN; seeking is instant; subtitle follow + tap-to-seek work.
- Entries without an uploaded video fall back to the YouTube embed (no regression).
- Backend signs 2h CDN URLs; desktop transcodes 720p + uploads via presigned PUT; iOS swaps players on `videoUrl` presence.
- All tests green (oss signCdnUrl + library upload-url/videoUrl); CI green; TestFlight build works.

## Notes
- Secrets (`OSS_*`, `CDN_*`) live only in `/opt/whatsub/.env` (user-set) — never in repo or chat. Backend degrades to 503 `oss_not_configured` (→ YouTube fallback) when unset.
- No CORS config needed (AVPlayer + reqwest are native, not browsers).
- Signed URL TTL 2h; iOS fetches a fresh `/entry` per detail open.
