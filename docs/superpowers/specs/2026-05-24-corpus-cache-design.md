# Corpus Persistent Cache — Design

**Date:** 2026-05-24
**Status:** design — pending user review before plan

## Problem / Goal

Today the iOS 语料库 hits the server too much:
- **Phrase detail**: every tap → `GET /api/corpus/lookup` (no cache; re-tapping the same phrase re-fetches).
- **List**: `browse`/`mine` + `tags` fetched once per session (in-memory only); cold launch always re-fetches.

Add a **persistent (on-disk) cache** so the corpus loads instantly, works offline, and stops re-hitting the server for phrases/lists that haven't changed — with correct invalidation when the corpus actually changes.

## Key decisions (agreed in brainstorming)

1. **Persistent = a JSON file on disk** in the app's **Caches** directory (`Caches/corpus_cache.json`). Caches (not Documents) because it's regenerable cache data: the OS may purge it under storage pressure (fine — we re-fetch), and it stays out of iCloud backup.
2. **Cache both scopes** (公共 + 个人) and both layers (list + per-phrase lookup).
3. **Invalidation via the existing `GET /api/corpus/versions`** → `{ mine: Int, public: Int }` (backend already has it for the desktop; **no backend change**). `public` bumps when the public corpus is published; `mine` bumps when the user contributes (desktop/plugin only — never from the phone). Every cached item is tagged with the `{mine, public}` pair it was fetched under; it's valid while the pair still matches the latest `/versions`.
4. **TTL backstop** of 24h: even if versions match, anything older than 24h is refetched (belt-and-suspenders against a missed bump).
5. **Lookup cache cap**: 500 entries, LRU eviction (most-recently-used kept).
6. **cache-first + background refresh**: show cached content instantly, then reconcile against `/versions` and refetch only what's stale.
7. **Only the unfiltered (no-tag) list is cached.** Tag-filtered `browse`/`mine` queries still go to the server (combinatorial; not worth caching). The lookup cache is unaffected by tags.

## Architecture / components (all iOS, `whatsub-mobile`)

- **DTO Codable** (`Networking/DTOs.swift`): make the corpus DTOs `Codable` (currently `Decodable`) so they round-trip to/from the cache file: `CorpusTag`, `CorpusSource`, `BrowsePhrase`, `MineItem`, `CorpusContribution`, `LookupResponse`. `LookupPhrase` has a custom `init(from:)` (tags arrive wrapped as `{list:[...]}`); add a matching `encode(to:)` that writes the **same wrapped shape** (and make its private `TagWrapper` `Codable`) so the existing decoder reads our cache back unchanged — the decoder is NOT modified.
- **`CorpusVersions`** DTO + **`WhatsubAPI.corpusVersions(token:)`** (`Networking/`): `GET /api/corpus/versions` → `{ mine, public }`. Swift can't name a property `public` (keyword) → decode with `CodingKeys { case mine; case publicVersion = "public" }`.
- **`CorpusCache`** (`Corpus/CorpusCache.swift`, a class; injectable file URL for tests): owns `Caches/corpus_cache.json`. Responsibilities: load/save the cache file; per-scope list accessors; per-phrase lookup accessors with LRU + cap; the current `{mine, public}` versions; staleness checks (version mismatch / TTL / empty). All file writes atomic; missing/corrupt → empty cache (never crash).
- **`CorpusViewModel`** (modify): cache-first list load + `/versions`-driven refresh.
- **`PhraseDetailViewModel`** (modify): serve from the lookup cache when valid; otherwise fetch + store.

## Cache file schema

```swift
struct CorpusCacheFile: Codable {
    var version = 1
    var mineVersion = -1            // last-known versions from /versions (-1 = unknown)
    var publicVersion = -1
    var browse = CachedList<BrowsePhrase>()   // public scope, unfiltered
    var mine   = CachedList<MineItem>()        // mine scope, unfiltered
    var lookups: [String: CachedLookup] = [:]  // phraseNormalized → entry
    var lookupOrder: [String] = []             // LRU; most-recent at the end
}
struct CachedList<T: Codable>: Codable {
    var items: [T] = []
    var tags: [CorpusTag] = []
    var fetchedAt: Double = 0      // epoch seconds
    var atMine = -1                // versions this list was fetched under
    var atPublic = -1
}
struct CachedLookup: Codable {
    var response: LookupResponse
    var fetchedAt: Double
    var atMine: Int
    var atPublic: Int
}
```

## Data flow + invalidation

### List (`CorpusViewModel.reload`)
1. On entry, if `selectedTags` is empty, **immediately** populate `browse`/`mine` + `tags` from `CorpusCache` (instant paint); keep `loading` only if the cache is empty.
2. Fetch `GET /versions` (one tiny request) → update the cache file's `mineVersion`/`publicVersion`.
3. Decide staleness for the current scope:
   - stale if: `selectedTags` non-empty (always go to server, don't cache) **OR** cached list empty **OR** the cached list's `atMine/atPublic` ≠ current versions for that scope (`public` for public scope, `mine` for mine scope) **OR** `now - fetchedAt > 24h`.
   - if **not** stale → done (no list fetch; the cached paint stands).
   - if stale → fetch `tags` + `browse`/`mine` from the server → update `@Published` → if `selectedTags` empty, store into the cache with the current versions + `fetchedAt = now`.
4. Errors (403 license / offline) behave as today, but a present cache means the user still sees content (show a subtle "离线/未刷新" only if you want — optional).

### Lookup (`PhraseDetailViewModel.load`)
1. Read `CorpusCache.cachedLookup(phrase)`. It's **valid** iff present AND `atMine == cache.mineVersion` AND `atPublic == cache.publicVersion` AND `now - fetchedAt < 24h`. (The versions come from the cache file, refreshed by the most recent list `reload` → `/versions`.)
2. Valid → show instantly, **no server call** (and bump LRU recency).
3. Invalid/absent → `GET /lookup` → show → `storeLookup(phrase, response, atMine: cache.mineVersion, atPublic: cache.publicVersion)`; enforce the 500-entry LRU cap (evict least-recently-used).

A phrase's detail combines public + personal contributions, so its validity is tied to **both** versions — if either changed since it was cached, it refetches. This is correct and cheap.

## Edge cases
- **No cache yet / first launch**: cache empty → behaves like today (fetch from server) → populates the cache.
- **Versions unknown (-1)**: treat as stale → fetch + record real versions.
- **Offline**: `/versions` or list/lookup fetch fails → fall back to whatever's cached (show it); surface the existing error only if there's nothing cached.
- **Corrupt/oversized cache file**: decode failure → start empty (no crash).
- **Tag-filtered views**: always server-fetched, never written to the unfiltered cache (so toggling tags doesn't pollute the default cache).
- **License lost (403) on public**: keep behaving as today (`licenseLocked`); don't serve a stale public cache as if licensed — clear/ignore public cache on 403.

## Testing
- **DTO Codable round-trip** (unit): encode then decode a `LookupResponse` (with wrapped tags), a `BrowsePhrase`, a `MineItem` → assert equality (esp. `LookupPhrase.tags` survives the wrap/unwrap).
- **`CorpusCache`** (unit, injected temp file): store/load list + lookup round-trip; `isListStale` true on version mismatch / TTL expiry / empty, false when fresh; lookup validity (version match + TTL); LRU cap evicts the least-recently-used at >500; missing/corrupt file → empty.
- **Manual e2e (TestFlight)**: open 语料库 (instant from cache after first load) → tap a phrase (instant on 2nd tap, no spinner) → force-quit + reopen (corpus + tapped phrases load instantly, offline too) → after the desktop publishes a public-corpus change, the phone refetches on next open (version bump).

## Out of scope (v1)
- Caching tag-filtered lists (only the unfiltered list is cached).
- Pagination/offset caching (the list is a single `limit=100` page today).
- A user-facing "clear cache" button (the OS purges Caches; can add later if needed).
- Prefetching lookups for visible list rows (only tapped phrases are cached).
