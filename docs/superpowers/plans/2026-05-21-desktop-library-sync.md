# Plan 3: Desktop Library Cloud Sync UI

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** Add a ☁️ "sync to cloud" button to each Library card on the desktop Tauri app. When clicked, push the entry's transcript + analysis + metadata to `https://whatsub.eversay.cc/api/library/sync`. iOS app will see the synced entries via `/api/library/list`.

**Architecture:** UI = React/SwiftUI-ish patterns already in `pages/Library.tsx`. Backend wiring = new Tauri commands in `src-tauri/src/commands/library.rs` (or new `library_sync.rs` module — TBD by Task 3 implementer based on file size). HTTP = reqwest reusing the `post_json` / `categorise_reqwest_error` pattern from `commands/license.rs`. Auth = bearer token read from `auth::get_auth(&app)`. `library.json` schema additive: 2 new optional fields (`syncedAt`, `syncError`).

**Tech Stack:** React 19 + TS + Vite · Tauri 2 · Rust + reqwest · tauri-plugin-store for auth.json + library.json reads · Vitest for TS · `cargo test` for Rust.

**Working dir:** `C:\Users\renjx\Desktop\Get_Video\client`. All file paths relative to that.

**Backend endpoints already live** (from Plan 1, in prod):
- `POST /api/library/sync` — body `{id, youtubeId, sourceUrl, title, durationSec?, thumbUrl?, transcriptSrt, analysisJson}` → `{ok: true}` or 400/401
- `DELETE /api/library/sync/:id` → `{ok: true}` or 404/401
- `GET /api/library/list` → `{entries: [...]}` (lightweight, no transcript/analysis)
- `GET /api/library/entry/:id` → full entry

All session-auth via `Authorization: Bearer <session token>`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `src/types/library.ts` | LibraryEntry TS type | Modify — add 2 optional fields |
| `src-tauri/src/commands/library.rs` OR new `library_sync.rs` | 3 new Tauri commands (sync / unsync / list_synced) | Modify or Create |
| `src-tauri/src/lib.rs` | Register new commands in `invoke_handler` | Modify |
| `src-tauri/capabilities/default.json` | Allow the new commands from the webview | Modify |
| `src/lib/syncSourceUrl.ts` | Extract YouTube ID from various source URLs | Create — pure util |
| `src/components/LibraryCard/SyncButton.tsx` | The ☁️ button with 4 states | Create |
| `src/components/LibraryCard/SyncDetailDialog.tsx` | "已同步" details + 「重新同步 / 从云删除」 actions | Create |
| `src/components/LibraryCard/index.tsx` (or wherever the card is rendered today in Library.tsx) | Wire SyncButton into the card UI | Modify |
| `src/pages/Library.tsx` | Page header: add 「云同步详情」 entry button | Modify (small) |
| `src/components/CloudSyncManager.tsx` | The 「云同步详情」 dialog — list + bulk下架 + 单条下架 | Create |
| `src/lib/api/librarySync.ts` | Thin TS wrappers around the 3 invoke commands | Create |
| `src-tauri/src/commands/library_sync.rs` tests OR `library.rs` test module | Test sync upsert / unsync / list_synced helpers (pure-memory helpers like existing `*_in_memory` pattern in library.rs) | Create or extend |
| `whatsub-mobile/docs/superpowers/plans/2026-05-21-desktop-library-sync.md` | This plan itself | Already created |

**Existing patterns to follow** (do NOT reinvent):
- Tauri command pattern: see `commands/license.rs::license_activate_http`
- Rust HTTP pattern: see `commands/license.rs::post_json` + `categorise_reqwest_error`
- Auth state read: `crate::auth::get_auth(&app_handle)` returns `Option<AuthState>` with `.session_token`
- Pure-memory test helpers: see `library.rs::*_in_memory` (e.g., `create_folder_in_memory`)
- React UI patterns: pages/Library.tsx (818 lines) — read it first to learn the LibraryCard rendering / drag-drop / overlap-detect

---

## Pre-flight (one-time)

- [ ] **Branch + baseline**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client
git status                          # working tree should be clean
git checkout main && git pull
git checkout -b feat/library-cloud-sync
pnpm install
pnpm typecheck                      # baseline: clean
pnpm test                           # baseline: green
cd src-tauri && cargo test --quiet  # baseline: green
cd ..
```

Expected: baseline all green before any code change. **If baseline fails, STOP — investigate first.**

---

### Task 1: Add `syncedAt` + `syncError` to LibraryEntry TS type

**Files:**
- Modify: `src/types/library.ts`

- [ ] **Step 1: Add optional fields to interface**

After line 19 (`analysisStyle?: TranslationStyle;`), add:

```typescript
  /** Unix ms — set when entry was last successfully uploaded to /api/library/sync.
   *  Undefined = never synced (or unsynced via deleteLibraryEntry on the backend).
   *  Phase 1 only YouTube-source entries get a value; others stay undefined. */
  syncedAt?: number;
  /** Friendly error message from the LAST sync attempt that failed.
   *  Cleared on next successful sync. Used by SyncButton to render the ✗ state
   *  + show the message in a tooltip / dialog. */
  syncError?: string;
```

- [ ] **Step 2: Typecheck (regression — adding optional fields shouldn't break anything)**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client && pnpm typecheck
```

Expected: no errors.

- [ ] **Step 3: Run existing tests (no test depends on absence of these fields)**

```bash
pnpm test --run 2>&1 | tail -5
```

Expected: same green count as baseline.

- [ ] **Step 4: Commit**

```bash
git add src/types/library.ts && git commit -m "feat(library/sync): LibraryEntry.syncedAt + syncError optional fields"
```

---

### Task 2: Add matching Rust struct fields for serde round-trip

**Files:**
- Modify: `src-tauri/src/models.rs` (or wherever LibraryEntry Rust struct lives — locate via `grep -n 'LibraryEntry' src-tauri/src/*.rs src-tauri/src/**/*.rs`)

- [ ] **Step 1: Locate the Rust LibraryEntry struct**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client/src-tauri
grep -rn "struct LibraryEntry" src/
```

- [ ] **Step 2: Add the 2 optional fields**

Mirror the TS additions. Use `Option<i64>` for `synced_at` (unix ms) and `Option<String>` for `sync_error`. Use serde rename to map to camelCase:

```rust
    #[serde(rename = "syncedAt", skip_serializing_if = "Option::is_none")]
    pub synced_at: Option<i64>,
    #[serde(rename = "syncError", skip_serializing_if = "Option::is_none")]
    pub sync_error: Option<String>,
```

`skip_serializing_if = "Option::is_none"` keeps the existing library.json shape backward-compatible (entries without sync state won't write the keys at all).

- [ ] **Step 3: cargo build + test**

```bash
cd src-tauri && cargo build --quiet 2>&1 | tail -10 && cargo test --quiet 2>&1 | tail -10
```

Expected: build clean, all existing tests pass.

- [ ] **Step 4: Verify backward-compat with an existing library.json**

Manually inspect: an existing user's `%APPDATA%/whatsub/library.json` (or the test fixture) should still read fine because:
- Rust deserialization treats absent JSON keys as `None` for `Option<T>` fields
- Rust serialization with `skip_serializing_if = "Option::is_none"` won't add new keys to entries that have never synced

If there's a fixture-based test (look in `src-tauri/tests/`), run it to confirm.

- [ ] **Step 5: Commit**

```bash
cd .. && git add src-tauri/src/models.rs && git commit -m "feat(library/sync): Rust LibraryEntry synced_at + sync_error fields"
```

---

### Task 3: YouTube ID extraction utility (TS)

**Files:**
- Create: `src/lib/syncSourceUrl.ts`
- Create: `src/lib/syncSourceUrl.test.ts`

- [ ] **Step 1: Write failing tests (TDD)**

`src/lib/syncSourceUrl.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { extractYouTubeId } from "./syncSourceUrl";

describe("extractYouTubeId", () => {
  it.each([
    ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"],
    ["https://youtu.be/dQw4w9WgXcQ", "dQw4w9WgXcQ"],
    ["https://youtu.be/dQw4w9WgXcQ?t=10", "dQw4w9WgXcQ"],
    ["https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123", "dQw4w9WgXcQ"],
    ["https://m.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"],
    ["https://www.youtube.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ"],
    ["https://www.youtube.com/shorts/abc123XYZ_-", "abc123XYZ_-"],
  ])("extracts %s → %s", (url, expected) => {
    expect(extractYouTubeId(url)).toBe(expected);
  });

  it.each([
    "https://www.bilibili.com/video/BV1xx411c7mu",
    "https://example.com/some-video",
    "https://www.youtube.com/playlist?list=PL123",
    "not a url",
    "",
  ])("returns null for non-YouTube URL: %s", (url) => {
    expect(extractYouTubeId(url)).toBeNull();
  });
});
```

- [ ] **Step 2: Run, verify RED**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client && pnpm test src/lib/syncSourceUrl.test.ts --run
```

Expected: all tests fail (`extractYouTubeId is not a function`).

- [ ] **Step 3: Implement**

`src/lib/syncSourceUrl.ts`:

```typescript
/**
 * Extract a YouTube video ID from a URL string. Returns null for any URL
 * that doesn't match a known YouTube pattern. Used by the library-sync
 * UI to decide whether to enable the ☁️ button (v1 only syncs YouTube
 * sources to keep backend storage tractable).
 *
 * Supported patterns:
 *   youtube.com/watch?v=ID         → ID
 *   youtu.be/ID                    → ID
 *   m.youtube.com/watch?v=ID       → ID
 *   youtube.com/embed/ID           → ID
 *   youtube.com/shorts/ID          → ID
 *
 * Excluded (returns null):
 *   playlist URLs (no specific video)
 *   non-YouTube hosts (bilibili, etc.)
 *   anything that doesn't parse as URL
 */
export function extractYouTubeId(url: string): string | null {
  if (!url) return null;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const host = parsed.hostname.toLowerCase();
  const isYtHost =
    host === "youtu.be" ||
    host === "youtube.com" ||
    host.endsWith(".youtube.com");
  if (!isYtHost) return null;

  // youtu.be/ID
  if (host === "youtu.be") {
    const id = parsed.pathname.replace(/^\//, "");
    return /^[A-Za-z0-9_-]{6,}$/.test(id) ? id : null;
  }
  // youtube.com/watch?v=ID
  if (parsed.pathname === "/watch") {
    const v = parsed.searchParams.get("v");
    return v && /^[A-Za-z0-9_-]{6,}$/.test(v) ? v : null;
  }
  // youtube.com/embed/ID  or  youtube.com/shorts/ID
  const m = parsed.pathname.match(/^\/(embed|shorts)\/([A-Za-z0-9_-]{6,})/);
  if (m) return m[2]!;
  return null;
}
```

- [ ] **Step 4: Run, verify GREEN**

```bash
pnpm test src/lib/syncSourceUrl.test.ts --run
```

Expected: 12/12 pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/syncSourceUrl.ts src/lib/syncSourceUrl.test.ts
git commit -m "feat(library/sync): extractYouTubeId util + TDD coverage"
```

---

### Task 4: Rust `library_sync_to_cloud` command

**Files:**
- Create: `src-tauri/src/commands/library_sync.rs`
- Modify: `src-tauri/src/commands/mod.rs` — `pub mod library_sync;`

- [ ] **Step 1: Sketch the module — empty handlers returning unimplemented**

Create `src-tauri/src/commands/library_sync.rs`:

```rust
//! Cloud-sync Tauri commands for library entries.
//!
//! POST /api/library/sync, DELETE /api/library/sync/:id, GET /api/library/list.
//! All session-auth via Bearer token read from crate::auth::get_auth.
//!
//! Wire format + endpoint contract are pinned in Plan 1's backend deploy
//! (whatsub-license/src/routes/library.ts). Update both sides in lockstep.

use crate::auth;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Runtime};

const API_BASE: &str = "https://whatsub.eversay.cc/api/library";
const NET_TIMEOUT_SECS: u64 = 30;

#[derive(Serialize)]
pub struct SyncOk {
    pub ok: bool,
    #[serde(rename = "syncedAt")]
    pub synced_at: i64,
}

#[tauri::command]
pub async fn library_sync_to_cloud<R: Runtime>(
    app: AppHandle<R>,
    id: String,
) -> Result<SyncOk, String> {
    Err("not implemented".into())
}

#[tauri::command]
pub async fn library_unsync_from_cloud<R: Runtime>(
    app: AppHandle<R>,
    id: String,
) -> Result<(), String> {
    Err("not implemented".into())
}

#[derive(Serialize, Deserialize)]
pub struct CloudLibraryEntry {
    pub id: String,
    #[serde(rename = "youtubeId")]
    pub youtube_id: String,
    #[serde(rename = "sourceUrl")]
    pub source_url: String,
    pub title: String,
    #[serde(rename = "durationSec")]
    pub duration_sec: Option<i64>,
    #[serde(rename = "thumbUrl")]
    pub thumb_url: Option<String>,
    #[serde(rename = "syncedAt")]
    pub synced_at: i64,
}

#[tauri::command]
pub async fn library_list_synced<R: Runtime>(
    app: AppHandle<R>,
) -> Result<Vec<CloudLibraryEntry>, String> {
    Err("not implemented".into())
}
```

Modify `src-tauri/src/commands/mod.rs` — add the new module to the `pub mod` list (locate where `pub mod library;` lives, add `pub mod library_sync;` next to it).

- [ ] **Step 2: Register the 3 new commands in `invoke_handler`**

Modify `src-tauri/src/lib.rs` (or wherever `tauri::Builder` is). Inside the `tauri::generate_handler!` macro list, add 3 entries:

```rust
commands::library_sync::library_sync_to_cloud,
commands::library_sync::library_unsync_from_cloud,
commands::library_sync::library_list_synced,
```

- [ ] **Step 3: cargo build (no test changes yet, just compile check)**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client/src-tauri && cargo build --quiet 2>&1 | tail -10
```

Expected: build clean.

- [ ] **Step 4: Commit scaffold**

```bash
cd .. && git add src-tauri/src/commands/library_sync.rs src-tauri/src/commands/mod.rs src-tauri/src/lib.rs
git commit -m "feat(library/sync): scaffold 3 Tauri commands (handlers stub to not implemented)"
```

---

### Task 5: Implement `library_sync_to_cloud` — reading library entry + posting

**Files:**
- Modify: `src-tauri/src/commands/library_sync.rs`

- [ ] **Step 1: Implement the handler**

Replace the stub `library_sync_to_cloud` with:

```rust
#[tauri::command]
pub async fn library_sync_to_cloud<R: Runtime>(
    app: AppHandle<R>,
    id: String,
) -> Result<SyncOk, String> {
    // 1. Auth: session token present + non-expired
    let auth_state = auth::get_auth(&app).ok_or("auth_required")?;
    if !auth::is_valid(&auth_state) {
        return Err("auth_required".into());
    }

    // 2. Read library entry from library.json (using existing library module)
    let library = crate::commands::library::read_index(&app)
        .map_err(|e| format!("library read: {e}"))?;
    let entry = library
        .videos
        .iter()
        .find(|v| v.id == id)
        .ok_or_else(|| "not_found".to_string())?;

    // 3. Validation: must be ready + YouTube source + analysis.json + transcript.srt exist
    if entry.status != crate::models::LibraryStatus::Ready {
        return Err("entry_not_ready".into());
    }
    let source_url = match &entry.source {
        crate::models::LibrarySource::Url { url } => url.clone(),
        _ => return Err("only_youtube_sources_supported".into()),
    };
    let youtube_id = extract_youtube_id_rust(&source_url)
        .ok_or_else(|| "not_youtube".to_string())?;

    let video_dir = entry
        .video_dir
        .as_deref()
        .ok_or_else(|| "missing video_dir".to_string())?;
    let analysis_path = std::path::Path::new(video_dir).join("analysis.json");
    let transcript_path = std::path::Path::new(video_dir).join("transcript.srt");
    let analysis_text = std::fs::read_to_string(&analysis_path)
        .map_err(|e| format!("analysis read: {e}"))?;
    let transcript_text = std::fs::read_to_string(&transcript_path)
        .map_err(|e| format!("transcript read: {e}"))?;
    let analysis_json: serde_json::Value = serde_json::from_str(&analysis_text)
        .map_err(|e| format!("analysis parse: {e}"))?;

    // 4. POST
    let body = serde_json::json!({
        "id": entry.id,
        "youtubeId": youtube_id,
        "sourceUrl": source_url,
        "title": entry.title,
        "durationSec": entry.duration_sec,
        "thumbUrl": format!("https://i.ytimg.com/vi/{youtube_id}/mqdefault.jpg"),
        "transcriptSrt": transcript_text,
        "analysisJson": analysis_json,
    });
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(NET_TIMEOUT_SECS))
        .build()
        .map_err(|e| format!("client build: {e}"))?;
    let resp = client
        .post(format!("{API_BASE}/sync"))
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {}", auth_state.session_token))
        .body(serde_json::to_string(&body).map_err(|e| format!("encode: {e}"))?)
        .send()
        .await
        .map_err(|e| categorise(&e))?;
    let status = resp.status();
    if !status.is_success() {
        let body_text = resp.text().await.unwrap_or_default();
        return Err(format!("http {}: {}", status.as_u16(), truncate(&body_text, 200)));
    }

    // 5. Persist syncedAt on the library entry
    crate::commands::library::set_synced_at(&app, &id, Some(now), None)
        .map_err(|e| format!("library write: {e}"))?;

    Ok(SyncOk { ok: true, synced_at: now })
}

fn extract_youtube_id_rust(url: &str) -> Option<String> {
    // Conservative parser — mirrors the TS extractYouTubeId for the same set
    // of patterns. Used server-side so the desktop can also derive youtube_id
    // without round-tripping through the JS layer.
    let parsed = url::Url::parse(url).ok()?;
    let host = parsed.host_str()?.to_lowercase();
    let is_yt = host == "youtu.be"
        || host == "youtube.com"
        || host == "www.youtube.com"
        || host == "m.youtube.com";
    if !is_yt {
        return None;
    }
    if host == "youtu.be" {
        let id = parsed.path().trim_start_matches('/');
        return id_valid(id).then(|| id.to_string());
    }
    if parsed.path() == "/watch" {
        return parsed.query_pairs().find(|(k, _)| k == "v")
            .and_then(|(_, v)| id_valid(&v).then(|| v.into_owned()));
    }
    for prefix in &["/embed/", "/shorts/"] {
        if let Some(rest) = parsed.path().strip_prefix(prefix) {
            let id = rest.split('/').next().unwrap_or("");
            if id_valid(id) {
                return Some(id.to_string());
            }
        }
    }
    None
}

fn id_valid(id: &str) -> bool {
    id.len() >= 6 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    s.chars().take(max).collect::<String>() + "..."
}

fn categorise(e: &reqwest::Error) -> String {
    if e.is_timeout() { format!("timeout: {e}") }
    else if e.is_connect() { format!("connect: {e}") }
    else { format!("network: {e}") }
}
```

This references two things that need to exist:
- `crate::commands::library::read_index(&app)` — likely already exists (used by other library commands). Verify by grep.
- `crate::commands::library::set_synced_at(&app, id, synced_at, sync_error)` — does NOT exist yet. Add it in Step 2 below.
- `crate::models::LibraryStatus::Ready` + `crate::models::LibrarySource::Url { url }` — verify enum variants by grep.
- `url::Url::parse` — `url` crate may or may not be a dep. Check `src-tauri/Cargo.toml`. If absent, add `url = "2"` under `[dependencies]`.

- [ ] **Step 2: Add `set_synced_at` helper to `commands/library.rs`**

In `commands/library.rs`, after the existing in-memory helpers, add:

```rust
/// Update synced_at + sync_error on a library entry by id. Used by the
/// library_sync command to record cloud-sync state. Saves the library
/// atomically (read-modify-write via existing library lock).
pub fn set_synced_at<R: Runtime>(
    app: &AppHandle<R>,
    id: &str,
    synced_at: Option<i64>,
    sync_error: Option<String>,
) -> Result<(), AppError> {
    let mut library = read_index(app)?;
    let entry = library
        .videos
        .iter_mut()
        .find(|v| v.id == id)
        .ok_or_else(|| "not_found".to_string())?;
    entry.synced_at = synced_at;
    entry.sync_error = sync_error;
    write_index(app, &library)?;
    Ok(())
}
```

(Adapt to the file's actual `AppError` / `AppHandle` import / `write_index` signature — read the surrounding code first.)

- [ ] **Step 3: cargo build + smoke**

```bash
cd src-tauri && cargo build --quiet 2>&1 | tail -15
```

If `url` crate missing, add it:

```bash
cargo add url --quiet 2>&1 | tail -3
```

then rebuild.

- [ ] **Step 4: cargo test (existing tests still pass)**

```bash
cargo test --quiet 2>&1 | tail -10
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
cd .. && git add src-tauri/src/commands/library_sync.rs src-tauri/src/commands/library.rs src-tauri/Cargo.toml src-tauri/Cargo.lock
git commit -m "feat(library/sync): library_sync_to_cloud command + set_synced_at helper"
```

---

### Task 6: Implement `library_unsync_from_cloud` + `library_list_synced`

**Files:**
- Modify: `src-tauri/src/commands/library_sync.rs`

- [ ] **Step 1: Implement `library_unsync_from_cloud`**

Replace the unsync stub:

```rust
#[tauri::command]
pub async fn library_unsync_from_cloud<R: Runtime>(
    app: AppHandle<R>,
    id: String,
) -> Result<(), String> {
    let auth_state = auth::get_auth(&app).ok_or("auth_required")?;
    if !auth::is_valid(&auth_state) {
        return Err("auth_required".into());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(NET_TIMEOUT_SECS))
        .build()
        .map_err(|e| format!("client build: {e}"))?;
    let resp = client
        .delete(format!("{API_BASE}/sync/{id}"))
        .header("authorization", format!("Bearer {}", auth_state.session_token))
        .send()
        .await
        .map_err(|e| categorise(&e))?;
    let status = resp.status();
    // 404 is also "successfully unsynced from the user's perspective" — the
    // cloud entry is gone either way. Only hard-fail on 5xx / network.
    if !status.is_success() && status.as_u16() != 404 {
        let body_text = resp.text().await.unwrap_or_default();
        return Err(format!("http {}: {}", status.as_u16(), truncate(&body_text, 200)));
    }
    // Clear local syncedAt
    crate::commands::library::set_synced_at(&app, &id, None, None)
        .map_err(|e| format!("library write: {e}"))?;
    Ok(())
}
```

- [ ] **Step 2: Implement `library_list_synced`**

```rust
#[tauri::command]
pub async fn library_list_synced<R: Runtime>(
    app: AppHandle<R>,
) -> Result<Vec<CloudLibraryEntry>, String> {
    let auth_state = auth::get_auth(&app).ok_or("auth_required")?;
    if !auth::is_valid(&auth_state) {
        return Err("auth_required".into());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(NET_TIMEOUT_SECS))
        .build()
        .map_err(|e| format!("client build: {e}"))?;
    let resp = client
        .get(format!("{API_BASE}/list"))
        .header("authorization", format!("Bearer {}", auth_state.session_token))
        .send()
        .await
        .map_err(|e| categorise(&e))?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| format!("read body: {e}"))?;
    if !status.is_success() {
        return Err(format!("http {}: {}", status.as_u16(), truncate(&text, 200)));
    }
    let parsed: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("parse: {e}"))?;
    let entries = parsed.get("entries").and_then(|v| v.as_array())
        .ok_or_else(|| "missing entries field".to_string())?;
    let mut out: Vec<CloudLibraryEntry> = Vec::with_capacity(entries.len());
    for v in entries {
        let entry: CloudLibraryEntry = serde_json::from_value(v.clone())
            .map_err(|e| format!("entry parse: {e}"))?;
        out.push(entry);
    }
    Ok(out)
}
```

- [ ] **Step 3: cargo build + test**

```bash
cd src-tauri && cargo build --quiet 2>&1 | tail -5 && cargo test --quiet 2>&1 | tail -5
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
cd .. && git add src-tauri/src/commands/library_sync.rs
git commit -m "feat(library/sync): library_unsync_from_cloud + library_list_synced"
```

---

### Task 7: Tauri capabilities permission

**Files:**
- Modify: `src-tauri/capabilities/default.json`

- [ ] **Step 1: Add the 3 new commands to the permission allowlist**

Read the existing `default.json`. Find the section that lists allowed commands (likely under `"permissions"` with entries like `"core:default"` or specific command names). Add 3 entries (adapt syntax to the existing pattern):

If the file uses `"core:command:identifier:library_xxx"` pattern:
```json
"core:command:identifier:library_sync_to_cloud",
"core:command:identifier:library_unsync_from_cloud",
"core:command:identifier:library_list_synced"
```

If it uses some other pattern (e.g., a single wildcard for all `commands::*`), no change needed — verify by examining the file.

- [ ] **Step 2: pnpm tauri dev sanity check**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client
# In a separate terminal:
pnpm tauri dev
```

App should boot without permission errors. Manually open devtools, run `await window.__TAURI__.core.invoke('library_list_synced')` in console. Expect either `Err("auth_required")` (if no auth.json yet) OR `Ok([])` (if logged in and nothing synced). The KEY assertion: the command is INVOCABLE — no "command not allowed" capability error.

Stop dev server (Ctrl-C).

- [ ] **Step 3: Commit**

```bash
git add src-tauri/capabilities/default.json
git commit -m "feat(library/sync): capability permission for 3 new commands"
```

---

### Task 8: TS API wrappers + LibraryCard SyncButton component

**Files:**
- Create: `src/lib/api/librarySync.ts`
- Create: `src/components/LibraryCard/SyncButton.tsx`
- Modify: `src/pages/Library.tsx` — render `<SyncButton>` inside each LibraryCard

- [ ] **Step 1: TS wrappers**

`src/lib/api/librarySync.ts`:

```typescript
import { invoke } from "@tauri-apps/api/core";

export interface CloudLibraryEntry {
  id: string;
  youtubeId: string;
  sourceUrl: string;
  title: string;
  durationSec: number | null;
  thumbUrl: string | null;
  syncedAt: number;
}

export interface SyncOk {
  ok: boolean;
  syncedAt: number;
}

export async function syncToCloud(id: string): Promise<SyncOk> {
  return invoke<SyncOk>("library_sync_to_cloud", { id });
}

export async function unsyncFromCloud(id: string): Promise<void> {
  await invoke("library_unsync_from_cloud", { id });
}

export async function listSynced(): Promise<CloudLibraryEntry[]> {
  return invoke<CloudLibraryEntry[]>("library_list_synced");
}

/** Maps the prefixed Rust error strings to friendly Chinese for tooltips/dialogs. */
export function friendlySyncError(raw: string): string {
  if (raw === "auth_required") return "需要先登录";
  if (raw === "not_found") return "本地条目找不到";
  if (raw === "entry_not_ready") return "条目还在解析中，等解析完再试";
  if (raw === "only_youtube_sources_supported") return "仅支持 YouTube 源";
  if (raw === "not_youtube") return "URL 不是 YouTube 链接";
  if (raw.startsWith("timeout:")) return "网络超时，检查 VPN 或重试";
  if (raw.startsWith("connect:")) return "连不上服务器，检查网络";
  if (raw.startsWith("http 401")) return "登录已过期，请重新登录";
  if (raw.startsWith("http ")) return `服务器返回 ${raw}`;
  return raw;
}
```

- [ ] **Step 2: SyncButton component with 4 states**

`src/components/LibraryCard/SyncButton.tsx`:

```tsx
import { useState } from "react";
import { Cloud, CloudOff, CloudCheck, Loader2 } from "lucide-react";
import { syncToCloud, friendlySyncError } from "../../lib/api/librarySync";
import { extractYouTubeId } from "../../lib/syncSourceUrl";
import type { LibraryEntry } from "../../types/library";

interface Props {
  entry: LibraryEntry;
  /** Called after a successful sync OR unsync so the parent can refresh
   *  library state from disk. The parent re-reads library.json via the
   *  existing useLibrary hook. */
  onChanged: () => void | Promise<void>;
}

type State = "idle" | "syncing" | "synced" | "failed";

export function SyncButton({ entry, onChanged }: Props) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(entry.syncError ?? null);

  const youtubeId = entry.source.type === "url" ? extractYouTubeId(entry.source.url) : null;
  const isYoutube = !!youtubeId;
  const isReady = entry.status === "ready";
  const enabled = isYoutube && isReady && !busy;

  const state: State =
    busy ? "syncing" :
    error ? "failed" :
    entry.syncedAt ? "synced" : "idle";

  async function handleClick(e: React.MouseEvent) {
    e.stopPropagation();
    if (!enabled) return;
    if (state === "idle" || state === "failed") {
      if (state === "idle") {
        const ok = window.confirm("同步到云？\n仅上传字幕 + 元数据，不上传视频文件。\niOS / 其他设备的 whatSub 能看到这条。");
        if (!ok) return;
      }
      setBusy(true);
      setError(null);
      try {
        await syncToCloud(entry.id);
        await onChanged();
      } catch (err) {
        setError(friendlySyncError(String(err)));
      } finally {
        setBusy(false);
      }
    } else if (state === "synced") {
      // Open details dialog — for simplicity in v1, route through onChanged's
      // parent which can open a SyncDetailDialog. For now, just confirm "re-sync"
      // inline.
      const action = window.confirm("已同步到云。\n点确定 → 重新同步；点取消 → 关闭。");
      if (action) {
        setBusy(true);
        setError(null);
        try { await syncToCloud(entry.id); await onChanged(); }
        catch (err) { setError(friendlySyncError(String(err))); }
        finally { setBusy(false); }
      }
    }
  }

  const tooltip = !isYoutube ? "仅 YouTube 源可云同步"
                : !isReady ? "等解析完成后再同步"
                : state === "failed" ? error ?? "同步失败"
                : state === "synced" ? `已同步 · ${new Date(entry.syncedAt!).toLocaleString()}`
                : "同步到云";

  return (
    <button
      onClick={handleClick}
      disabled={!enabled && state !== "synced"}
      title={tooltip}
      className={`
        h-7 w-7 grid place-items-center rounded-full transition-colors
        ${state === "synced" ? "text-emerald-400 hover:bg-emerald-500/15" : ""}
        ${state === "failed" ? "text-rose-400 hover:bg-rose-500/15" : ""}
        ${state === "idle" ? "text-zinc-400 hover:text-zinc-200 hover:bg-white/10" : ""}
        ${state === "syncing" ? "text-zinc-300" : ""}
        ${!enabled && state !== "synced" ? "opacity-40 cursor-not-allowed" : ""}
      `}
    >
      {state === "syncing" && <Loader2 className="h-4 w-4 animate-spin" />}
      {state === "synced" && <CloudCheck className="h-4 w-4" />}
      {state === "failed" && <CloudOff className="h-4 w-4" />}
      {state === "idle" && <Cloud className="h-4 w-4" />}
    </button>
  );
}
```

- [ ] **Step 3: Wire SyncButton into LibraryCard inside `pages/Library.tsx`**

Read `src/pages/Library.tsx` to locate the LibraryCard render (around the per-video-card section). Add an `<SyncButton>` element in the top-right corner of the card, near the existing delete/edit overlay (look for an overlay div like `absolute top-2 right-2`). Pass `onChanged={() => refreshLibrary()}` (using whatever the existing library-refresh function is — likely `useLibrary()`'s reload or a similar hook method).

Sketch:
```tsx
<div className="absolute top-2 right-2 flex items-center gap-1">
  <SyncButton entry={video} onChanged={refreshLibrary} />
  {/* existing delete + edit buttons */}
</div>
```

(Adapt to the actual existing JSX.)

- [ ] **Step 4: typecheck + test**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client
pnpm typecheck
pnpm test --run 2>&1 | tail -5
```

Expected: clean. (No tests for the new component yet; manual UX verification in next task.)

- [ ] **Step 5: Commit**

```bash
git add src/lib/api/librarySync.ts src/components/LibraryCard/SyncButton.tsx src/pages/Library.tsx
git commit -m "feat(library/sync): SyncButton with 4 states + TS API wrappers"
```

---

### Task 9: Delete-coordination prompt

**Files:**
- Modify: wherever delete is wired in `src/pages/Library.tsx` or a sub-component

- [ ] **Step 1: Add a confirm step when deleting a synced entry**

Find the existing delete handler (search for `library_delete_video` or `removeLibraryEntry`). Wrap it:

```tsx
async function handleDelete(entry: LibraryEntry) {
  if (entry.syncedAt) {
    const choice = window.confirm(
      "这个条目已同步到云（iOS 可见）。\n\n" +
      "点【确定】= 同步从云上删除 + 删本地\n" +
      "点【取消】= 不删任何东西",
    );
    if (!choice) return;
    try {
      await unsyncFromCloud(entry.id);
    } catch (err) {
      const proceed = window.confirm(
        `从云上删除失败: ${friendlySyncError(String(err))}\n\n` +
        "继续删本地吗？（云端那条会变成孤儿，可以稍后在「云同步详情」里手动下架）",
      );
      if (!proceed) return;
    }
  }
  // Existing delete path
  await invoke("library_delete_video", { id: entry.id });
  await refreshLibrary();
}
```

(Adapt parameter names / function names to match existing code.)

- [ ] **Step 2: Manual UX smoke (pnpm tauri dev)**

In dev, manually:
1. Sync a YouTube entry → entry shows 🟢 CloudCheck
2. Try to delete it → see the new confirm prompt
3. Click 确定 → entry deleted locally + cloud (verify via separate "云同步详情" check, Task 11)
4. Click 取消 on the prompt → entry stays

- [ ] **Step 3: Commit**

```bash
git add src/pages/Library.tsx  # (or wherever delete handler lives)
git commit -m "feat(library/sync): delete prompts coordinate cloud unsync for synced entries"
```

---

### Task 10: "云同步详情" entry button on Library page header

**Files:**
- Modify: `src/pages/Library.tsx` — page header
- Create: `src/components/CloudSyncManager.tsx`

- [ ] **Step 1: CloudSyncManager dialog component**

`src/components/CloudSyncManager.tsx`:

```tsx
import { useEffect, useState } from "react";
import { X, Trash2 } from "lucide-react";
import { listSynced, unsyncFromCloud, friendlySyncError, type CloudLibraryEntry } from "../lib/api/librarySync";

interface Props { onClose: () => void; onChanged: () => void | Promise<void>; }

export function CloudSyncManager({ onClose, onChanged }: Props) {
  const [entries, setEntries] = useState<CloudLibraryEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyIds, setBusyIds] = useState<Set<string>>(new Set());

  async function reload() {
    setEntries(null);
    setError(null);
    try {
      setEntries(await listSynced());
    } catch (err) {
      setError(friendlySyncError(String(err)));
    }
  }
  useEffect(() => { void reload(); }, []);

  async function unsync(id: string) {
    if (!window.confirm("从云端下架这条？iOS 上将不再可见。\n本地条目不会被删。")) return;
    setBusyIds(prev => new Set(prev).add(id));
    try {
      await unsyncFromCloud(id);
      setEntries(prev => prev?.filter(e => e.id !== id) ?? null);
      await onChanged();
    } catch (err) {
      window.alert(friendlySyncError(String(err)));
    } finally {
      setBusyIds(prev => { const next = new Set(prev); next.delete(id); return next; });
    }
  }

  async function unsyncAll() {
    if (!entries?.length) return;
    if (!window.confirm(`从云端下架全部 ${entries.length} 条？\n本地条目不会被删。`)) return;
    for (const e of entries) {
      try { await unsyncFromCloud(e.id); } catch { /* swallow + continue */ }
    }
    await reload();
    await onChanged();
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/60 backdrop-blur-sm" onClick={onClose}>
      <div className="w-[640px] max-h-[80vh] flex flex-col rounded-2xl bg-zinc-900 border border-white/10 shadow-2xl" onClick={e => e.stopPropagation()}>
        <header className="flex items-center justify-between px-5 py-4 border-b border-white/10">
          <h2 className="text-base font-semibold text-white">云同步详情</h2>
          <button onClick={onClose} className="text-zinc-400 hover:text-white"><X size={18} /></button>
        </header>
        <div className="flex-1 overflow-y-auto p-5 space-y-3">
          {entries === null && !error && <div className="text-zinc-400 text-sm">加载中…</div>}
          {error && <div className="text-rose-400 text-sm">{error}</div>}
          {entries?.length === 0 && <div className="text-zinc-500 text-sm py-8 text-center">还没同步过任何条目。<br/>在 Library 卡片上点 ☁️ 同步。</div>}
          {entries?.map(e => (
            <div key={e.id} className="flex items-center gap-3 rounded-lg bg-zinc-800/50 p-3">
              {e.thumbUrl && <img src={e.thumbUrl} alt="" className="h-12 w-20 rounded object-cover bg-zinc-700" />}
              <div className="flex-1 min-w-0">
                <div className="truncate text-sm text-white">{e.title}</div>
                <div className="text-xs text-zinc-500 mt-0.5">同步于 {new Date(e.syncedAt).toLocaleString()}</div>
              </div>
              <button
                onClick={() => unsync(e.id)}
                disabled={busyIds.has(e.id)}
                className="grid place-items-center h-8 w-8 rounded text-rose-400 hover:bg-rose-500/15 disabled:opacity-40"
                title="从云下架"
              >
                <Trash2 size={16} />
              </button>
            </div>
          ))}
        </div>
        {entries && entries.length > 0 && (
          <footer className="px-5 py-3 border-t border-white/10 flex justify-end gap-2">
            <button onClick={unsyncAll} className="text-sm text-rose-400 hover:text-rose-300">全部下架</button>
            <button onClick={onClose} className="text-sm text-zinc-300 hover:text-white px-3 py-1 rounded bg-zinc-800">关闭</button>
          </footer>
        )}
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Library page header button**

In `pages/Library.tsx`, find the page header (top bar with "Library" title or filter chips). Add a 「云同步详情」 button:

```tsx
const [showCloudManager, setShowCloudManager] = useState(false);

// ...inside the page header JSX:
<button
  onClick={() => setShowCloudManager(true)}
  className="text-sm text-zinc-400 hover:text-white px-3 py-1 rounded hover:bg-white/5"
>
  ☁️ 云同步详情
</button>

// ...near the bottom of the page render:
{showCloudManager && (
  <CloudSyncManager
    onClose={() => setShowCloudManager(false)}
    onChanged={refreshLibrary}
  />
)}
```

- [ ] **Step 3: typecheck + test**

```bash
pnpm typecheck && pnpm test --run 2>&1 | tail -3
```

- [ ] **Step 4: Commit**

```bash
git add src/components/CloudSyncManager.tsx src/pages/Library.tsx
git commit -m "feat(library/sync): 云同步详情 dialog — list + unsync + bulk下架"
```

---

### Task 11: Manual end-to-end smoke test

**Files:** none (manual verification)

- [ ] **Step 1: Build + run dev**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client && pnpm tauri dev
```

- [ ] **Step 2: Walk through scenarios**

1. Open Library page. Confirm ☁️ buttons appear on existing YouTube entries; disabled (greyed) on non-YouTube entries.
2. Click ☁️ on a YouTube entry → confirm dialog appears → click 同步 → button spins → settles to 🟢 CloudCheck.
3. Click 🟢 → re-sync prompt → choose to re-sync → button refreshes.
4. Page header → click 「云同步详情」 → dialog opens → entry appears.
5. In the dialog, click 🗑️ on the entry → confirm → entry vanishes from the dialog. Reload dialog → still empty.
6. Re-sync → delete entry from Library page → see new prompt asking about cloud → click 确定 → entry deleted locally + cloud.
7. Confirm 在 iOS TestFlight 上能看到同步过的条目（暂时没有 list 页，可以用 curl + session token 验证）。

- [ ] **Step 3: No commit needed** (no code changes)

If something looks broken, fix in a new Task at the implementer's discretion.

---

### Task 12: Merge feature branch + push

**Files:** none (git ops)

- [ ] **Step 1: Verify state**

```bash
cd /c/Users/renjx/Desktop/Get_Video/client
git status                          # clean
git log --oneline main..HEAD        # ~10 commits on feat/library-cloud-sync
```

- [ ] **Step 2: Merge to main**

```bash
git checkout main
git merge --no-ff feat/library-cloud-sync -m "feat(library/sync): cloud sync UI + 3 Tauri commands"
git push origin main
git branch -d feat/library-cloud-sync
```

NO release artifact bump — this feature ships in the next desktop release (v0.1.54 or whenever the user decides). Existing v0.1.53 users get nothing until the next bundled release. That's deliberate per spec — Plan 2 (iOS) needs to be tested with data, and the simplest data path is the developer (you) syncing a few entries via dev build.

---

## Done criteria

After this plan:
- Desktop user can click ☁️ on YouTube library cards → entry uploaded to `/api/library/sync`
- Failed syncs show ✗ with friendly error tooltip
- Re-syncs + cloud-unsync work
- 「云同步详情」 dialog lists all cloud entries + supports per-row and bulk unsync
- Delete on a synced entry prompts to also unsync cloud
- ~10 commits merged to main on `Get_Video/client`
- iOS TestFlight (Plan 2 Phase 2) will have real data to test against

Ready for **Plan 2 Phase 2** (iOS auth + corpus + library detail features) once user has synced a few sample videos.
