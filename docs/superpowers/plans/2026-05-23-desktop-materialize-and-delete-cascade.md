# Desktop: Materialize Cloud Entry + Delete-Cascade Dialog — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** (Q1) Let the desktop "下载到本地" a cloud-only entry (e.g. a phone-imported, captions-only video): download the video + reuse the cloud's transcript+analysis → a full local entry the desktop Player can play (no re-whisper/re-LLM). (Q2) When deleting a SYNCED video locally, ask "也从云端移除吗?".

**Architecture:** All desktop (`Get_Video/client`); backend unchanged (reuses `GET /api/library/entry/:id`). Q1 = new Rust command `library_materialize_from_cloud` (reqwest fetch entry → `ytdlp::download` → write transcript.srt + `save_analysis` → `library_upsert`) + a "下载到本地" button in CloudSyncManager. Q2 = frontend delete flow gains a cascade dialog reusing `unsyncFromCloud`.

**Reuse (verified):** `ytdlp::download` (pipeline/ytdlp.rs:190), `save_analysis(video_id, Value)` (commands/analysis.rs:14), `library_upsert` (commands/library.rs), `library_list_synced` (commands/library_sync.rs:204 — mirror its reqwest+auth+API_BASE for the new fetch), `unsyncFromCloud` (lib/api/librarySync.ts), the CloudSyncManager + Library delete UI.

---

## PART Q1 — Materialize cloud entry to local

### Pre-flight: `cd /c/Users/renjx/Desktop/Get_Video/client && git checkout main && git pull && git checkout -b feat/desktop-materialize`

### Task 1: Rust command `library_materialize_from_cloud`

**Files:** `src-tauri/src/commands/library_sync.rs` (add the command) + register in `src-tauri/src/lib.rs`

- [ ] **Step 1:** Add a command that fetches the full cloud entry + downloads + writes locally. Mirror `library_list_synced`'s auth + reqwest + `API_BASE`. Sketch:
```rust
#[tauri::command]
pub async fn library_materialize_from_cloud(app: AppHandle, id: String) -> Result<(), String> {
    let auth_state = auth::get_auth(&app).ok_or_else(|| "auth_required".to_string())?;
    if !auth::is_valid(&auth_state) { return Err("auth_required".into()); }

    // 1. GET /api/library/entry/:id → full entry (transcriptSrt + analysisJson + meta)
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(NET_TIMEOUT_SECS)).build()
        .map_err(|e| format!("client build: {e}"))?;
    let resp = client
        .get(format!("{API_BASE}/entry/{id}"))
        .header("authorization", format!("Bearer {}", auth_state.session_token))
        .send().await.map_err(|e| categorise(&e))?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| format!("read body: {e}"))?;
    if !status.is_success() { return Err(format!("http {}: {}", status.as_u16(), truncate(&text, 200))); }
    let entry_json: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("parse: {e}"))?;

    let source_url = entry_json["sourceUrl"].as_str().unwrap_or_default().to_string();
    let youtube_id = entry_json["youtubeId"].as_str().unwrap_or(&id).to_string();
    let title = entry_json["title"].as_str().unwrap_or("Untitled").to_string();
    let duration_sec = entry_json["durationSec"].as_f64().unwrap_or(0.0);
    let transcript = entry_json["transcriptSrt"].as_str().unwrap_or_default().to_string();
    let analysis = entry_json["analysisJson"].clone();
    if source_url.is_empty() { return Err("missing sourceUrl".into()); }

    // 2. Download the video locally (reuse the import download path).
    let out_dir = crate::core::paths::video_dir(&id).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&out_dir).map_err(|e| e.to_string())?;
    let dl = crate::pipeline::ytdlp::download(&app, &source_url, &out_dir, &id, "standard", true, None)
        .await.map_err(|e| e.to_string())?;

    // 3. Write transcript.srt + analysis.json from the cloud data (NO re-analysis).
    std::fs::write(out_dir.join("transcript.srt"), &transcript).map_err(|e| e.to_string())?;
    crate::commands::analysis::save_analysis(id.clone(), analysis).map_err(|e| e.to_string())?;

    // 4. Create the local library entry (ready + synced, since it came from cloud).
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
    let entry = crate::commands::library::LibraryEntry {
        id: id.clone(),
        title,
        source: crate::commands::library::LibrarySource::Url { url: source_url },
        duration_sec: if duration_sec > 0.0 { duration_sec } else { dl.duration_sec },
        thumbnail_path: dl.thumb_path,
        created_at: chrono::Utc::now().to_rfc3339(),
        status: crate::commands::library::LibraryStatus::Ready,
        last_error: None,
        video_dir: Some(out_dir.to_string_lossy().to_string()),
        analysis_style: None,
        synced_at: Some(now),
        sync_error: None,
    };
    crate::commands::library::library_upsert(entry).map_err(|e| e.to_string())?;
    Ok(())
}
```
(VERIFY against the real code: `ytdlp::download`'s exact param list (read ytdlp.rs:190 — quality string, background bool, cancel Option) + `LibraryEntry`'s exact fields (read library.rs — the materialize fix already touched it) + `save_analysis` takes `(String, Value)`. Adjust types to match. `chrono` is already a dep (import.rs uses Utc::now).)
- [ ] **Step 2:** Register `library_materialize_from_cloud` in `src-tauri/src/lib.rs` invoke_handler. `cargo build --quiet` clean. Commit: `feat(materialize): library_materialize_from_cloud command`

### Task 2: "下载到本地" button in CloudSyncManager

**Files:** `src/lib/api/librarySync.ts` (+ wrapper) + `src/components/CloudSyncManager.tsx`

- [ ] **Step 1:** `librarySync.ts`: `export async function materializeFromCloud(id: string) { return invoke("library_materialize_from_cloud", { id }); }`
- [ ] **Step 2:** `CloudSyncManager.tsx`: for each cloud entry, add a "下载到本地" button (show a spinner while running). On click → `materializeFromCloud(id)` → on success `await useLibrary.getState().reload()` + a toast "已下载到本地，可在库中播放". Handle errors (show message). Disable while in-flight. (Optional: only show the button when the entry isn't already local — check `useLibrary` videos for the id.)
- [ ] **Step 3:** `pnpm typecheck` clean. Commit: `feat(materialize): 下载到本地 button in CloudSyncManager`

---

## PART Q2 — Delete-cascade dialog

### Task 3: ask "也从云端移除吗?" on local delete of a synced video

**Files:** `src/store/library.ts` + the Library delete UI (`src/pages/Library.tsx` — find the delete confirm/handler)

- [ ] **Step 1:** Find where the desktop deletes a video (the library store `remove(id)` + the Library page's delete button/confirm). Currently `remove(id)` → `invoke("library_delete", {id})` → reload (local only).
- [ ] **Step 2:** In the delete flow, when the target video has `syncedAt` set (it's synced), show a dialog with three choices: "仅删本地" / "本地 + 云端都删" / "取消". 
  - 仅删本地 → `library_delete` (current behavior).
  - 本地 + 云端 → `unsyncFromCloud(id)` (DELETE /sync/:id, also removes the OSS object) THEN `library_delete(id)`.
  - For an UNsynced video, delete directly (no dialog) as today.
  Implement the dialog where the existing delete confirm lives (match the app's existing dialog/confirm pattern — study Library.tsx). Reuse `unsyncFromCloud` from librarySync.ts.
- [ ] **Step 3:** `pnpm typecheck` clean. Commit: `feat(library): ask to also remove from cloud when deleting a synced video`

---

## Verify / Done
- `cargo build` + `pnpm typecheck` clean. Manual (`pnpm tauri dev`): 
  - Q1: a phone-imported (cloud-only) entry → CloudSyncManager → 下载到本地 → it downloads + appears in the local Library, plays with the cloud transcript+analysis.
  - Q2: delete a synced video locally → dialog asks about cloud → "本地+云端" removes both (gone from phone too); "仅本地" keeps the cloud copy.
- Merge — PAUSE for user (`pnpm tauri dev` verify; desktop ships on release, no deploy).

## Notes
- Backend unchanged. Q1 reuses GET /entry/:id (returns transcriptSrt + analysisJson).
- Q1 reuses the cloud analysis (no re-whisper/re-LLM) — fast. It DOES re-download the video (the only missing piece locally).
- The materialize fix from earlier (read_index orphan reconcile) ensures the new local entry shows in the main Library.
