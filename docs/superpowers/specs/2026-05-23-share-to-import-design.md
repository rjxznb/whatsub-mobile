# Share-to-Import (YouTube → whatSub, client-side) — Design

**Date:** 2026-05-23
**Status:** design — pending user review before plan

## Problem / Goal

Let the user import a video into whatSub directly from their phone: in the YouTube (later Bilibili) app, **Share → whatSub** → the app extracts the captions, runs LLM analysis (bilingual + AI highlights) using the user's own LLM key, shows a reading preview, and optionally syncs it to the cloud library (so it appears on both phone and desktop). No desktop required.

## Key decisions (agreed in brainstorming)

- **All client-side.** Caption extraction + LLM analysis happen on the phone (the phone, with VPN, can reach YouTube; the China backend cannot). The backend stays a dumb store — reuses the existing `POST /api/library/sync`.
- **User's own LLM key**, client-side calls (like the desktop/plugin). v1 supports **openai-compatible only** (DeepSeek default); Claude/Gemini later.
- **YouTube first**, Bilibili second — via a pluggable `CaptionExtractor` (YouTube extraction is already battle-tested in the plugin; Bilibili's API coverage is unverified).
- **Captions-only** (no whisper, no video download/re-hosting). A video must have captions to import. App-Store-safe (text extraction + watch on the existing YouTube embed; no content re-hosting).
- **Selective sync.** Import → analyze → preview → a "同步到云库" button (like the desktop ☁️) pushes to cloud; otherwise discard.

## The hard-won fact (why it must be WKWebView, not URLSession)

YouTube's `/api/timedtext` requires a **po_token** (2024 anti-scrape) that cannot be forged. The plugin's solution (proven): **inject a MAIN-world fetch hook that intercepts the player's own already-signed timedtext request.** iOS must do the same — there is NO clean URLSession path. We already have a WKWebView running the YouTube player (`YouTubeEmbedView`), so we inject the same hook there.

## Architecture

```
YouTube app → Share → whatSub Share Extension
  → save URL to App Group + open main app (deep link whatsub://import?url=…)

Main app (ImportFlow):
  1. CaptionExtractor (pluggable by source)
     YouTube: hidden WKWebView loads the video + injects fetchHook.js (port)
       → enable CC → player fetches /api/timedtext (po_token-signed)
       → WKScriptMessageHandler captures body → parseTimedtextJson3 (port) → [Cue]
  2. LLMAnalyzer (user's openai-compatible key, client-side)
     chunk cues → /chat/completions (structured prompt, ref llm-core/batchSubtitles)
       → AnalysisJson { subtitles[{time,endTime,text,translation,isKeyPoint,
                                    highlightWords,keyNotes,highlightTranslations}], keyPhrases }
  3. Preview (reuse the Library detail reading UI on the in-memory result)
  4. "同步到云库" → POST /api/library/sync (EXISTING) → appears in Library tab
```

## Components (with port references — all in `C:\Users\renjx\Desktop\whatsub-plugin`)

| Component | Responsibility | Port reference |
|---|---|---|
| **Share Extension** (new Xcode target in `project.yml`) | Accept a shared URL (NSExtension, public.url) → write to App Group → open `whatsub://import?url=…`. Minimal work (extensions are memory/time-limited). | — (iOS-native; App Group entitlement on both targets) |
| **`CaptionExtractor` protocol** | `func extract(url) async throws -> [Cue]`. Per-source impls. | — |
| **`YouTubeCaptionExtractor`** | Hidden WKWebView + inject `fetchHook.js` (MAIN world, documentStart via `WKUserScript`) + WKScriptMessageHandler("whatsub-yt-fetch-hook") → capture timedtext body → parse. Trigger: load the watch page (or embed), enable CC so the player fetches the full track ("全片预加载"). | `web-plugin/public/fetchHook.js` (verbatim JS), `web-plugin/src/cs/youtube/{injectFetchHook,extractCaptionTracks,index}.ts` (orchestration) |
| **`parseTimedtextJson3`** (Swift) | json3 `{events:[{tStartMs,dDurationMs,segs:[{utf8}]}]}` → `[Cue]`. | `web-plugin/src/sw/transcripts/parseTimedtextJson3.ts` (direct port, ~25 lines) |
| **`LLMAnalyzer`** (Swift) | Chunk cues by token budget → openai-compatible `/chat/completions` with a structured prompt → bilingual + highlights JSON → assemble `AnalysisJson`. Progress callback. | `packages/llm-core/src/batchSubtitles.ts` + the plugin/desktop prompts |
| **LLM Settings** (我的 tab) | provider=openai-compatible, `baseUrl`/`apiKey`/`model` (default `https://api.deepseek.com/v1` / `deepseek-chat`). Stored in Keychain. | desktop `src/types/settings.ts` (the `openaiCompatible` slot) |
| **ImportFlowView** | Orchestrates extract→analyze with progress, then preview + sync button. Preview reuses the cue-rendering UI (`CueRow`/`splitForHighlights`). | — (reuses existing iOS Library detail UI) |
| **Sync** | `WhatsubAPI.syncLibraryEntry(...)` → `POST /api/library/sync` (EXISTING). Build the entry: id=youtubeId, youtubeId, sourceUrl, title, transcriptSrt (from cues), analysisJson. | backend unchanged |

## Data flow notes
- `Cue` (extractor output: idx/time/end/text) → `AnalysisJson.subtitles` (LLM fills translation + highlights). `transcriptSrt` is generated from the cues for the sync payload.
- The synced entry has `youtubeId` set → the Library detail plays it via the existing YouTube embed (needs VPN, as today). No OSS video for imports (captions-only).
- The Library list cover: reuse `i.ytimg.com/vi/{id}/mqdefault.jpg` (or the thumbnail-sync path doesn't apply — imports have no desktop thumb; the YouTube CDN cover is fine, needs VPN like the player).

## App Store / legal
- Import extracts **caption text** + analyzes; the **video is watched via the existing YouTube embed** (not downloaded or re-hosted). This is the App-Store-safe framing (text, not media ripping). Same posture as the existing YouTube-embed Library.

## Risks
1. **WKWebView caption-fetch orchestration** (main risk): reliably getting the player to fetch the full timedtext (enable CC + trigger) then intercepting it, headlessly. The plugin does this passively while the user watches; we do it proactively. Mitigation: a focused spike on the WKWebView+hook capture before building the rest.
2. **VPN required** for import (YouTube unreachable in China) — consistent with watching YouTube anyway; surface a hint.
3. **LLM cost/time on the user's key** — a long video = many cues = several `/chat/completions` calls (minutes, the user's tokens). Show progress; chunk sensibly.
4. **Caption coverage** — videos without captions can't import (show "无字幕，无法导入"). The plugin's InnerTube/DOM fallbacks are NOT ported in v1 (just the primary hook); some videos the plugin handles may fail on iOS.
5. **Share Extension + App Group** signing (new target, entitlements, bundle id `cc.eversay.whatsub.mobile.share`).

## Phasing (this is large — decompose)

- **Phase 0 (spike, ~half day):** WKWebView + `fetchHook.js` + a hard-coded YouTube URL → confirm we can capture + `parseTimedtextJson3` the timedtext on iOS. Go/no-go for the whole approach.
- **Phase 1:** In-app import (no share extension yet): a "导入" button + URL paste field → YouTubeCaptionExtractor → LLMAnalyzer → preview → sync. + LLM Settings. (Delivers the whole value loop, testable without the extension.)
- **Phase 2:** Share Extension (YouTube app → Share → whatSub → deep link into the Phase 1 flow).
- **Phase 3:** Bilibili `CaptionExtractor` (verify API first) + Bilibili player embed + backend source-type.

## Out of scope (v1)
- whisper fallback for caption-less videos.
- Claude/Gemini LLM providers (openai-compatible only).
- Video download / OSS self-hosting for imports (watch on YouTube embed).
- Porting the plugin's full fallback stack (InnerTube multi-client / DOM scrape).

## Testing
- parseTimedtextJson3 Swift port: unit tests (json3 fixture → cues).
- LLMAnalyzer: unit test the chunking + the JSON assembly (mock LLM response).
- Phase 0 spike: manual (real YouTube URL, VPN on).
- End-to-end: import a real captioned YouTube video → analyze → preview → sync → appears in Library.
