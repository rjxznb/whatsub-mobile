# Corpus Persistent Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the iOS 语料库 (list + per-phrase lookup) to disk so it loads instantly, works offline, and stops re-hitting the server for content that hasn't changed — invalidated by `GET /api/corpus/versions` + a 24h TTL.

**Architecture:** Make the corpus DTOs `Codable`, add a `CorpusCache` disk store (`Caches/corpus_cache.json`) tagged with `{mine, public}` versions, and wire cache-first reads into `CorpusViewModel` (list) and `PhraseDetailViewModel` (lookup). Backend unchanged (`/versions` already exists).

**Tech Stack:** SwiftUI / Foundation (Codable, FileManager), XCTest. iOS 16 deployment target — **no iOS-17-only APIs**. Built in CI (can't compile on Windows).

**Spec:** `docs/superpowers/specs/2026-05-24-corpus-cache-design.md`

**Branch + push:** all work on `feat/ios-corpus-cache` (spec already committed there). Commit LOCALLY per task; the controller pushes once at the end (Task 6) → CI + TestFlight.

---

## File Structure

- Modify `whatsub-mobile/Networking/DTOs.swift` — corpus DTOs `Decodable` → `Codable` (+ `LookupPhrase.encode`, `CorpusVersions`).
- Modify `whatsub-mobile/Networking/WhatsubAPI.swift` — add `corpusVersions(token:)`.
- Create `whatsub-mobile/Corpus/CorpusCache.swift` — the disk cache (models + store).
- Modify `whatsub-mobile/Corpus/CorpusViewModel.swift` — cache-first list + version refresh.
- Modify `whatsub-mobile/Corpus/PhraseDetailViewModel.swift` — lookup cache.
- Test `whatsub-mobileTests/CorpusCodableTests.swift` — DTO round-trip.
- Test `whatsub-mobileTests/CorpusCacheTests.swift` — store/staleness/LRU.

---

## Task 1: Make corpus DTOs Codable (TDD)

**Files:**
- Modify: `whatsub-mobile/Networking/DTOs.swift`
- Test: `whatsub-mobileTests/CorpusCodableTests.swift`

- [ ] **Step 1: Write the failing round-trip test**

Create `whatsub-mobileTests/CorpusCodableTests.swift`:
```swift
import XCTest
@testable import whatsub_mobile

final class CorpusCodableTests: XCTestCase {
    private func decode<T: Decodable>(_ t: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testLookupResponseRoundTripsThroughOurEncoder() throws {
        // Server shape: tags wrapped as { list: [...] }.
        let serverJSON = """
        {"phrase":{"phrase_raw":"kick the bucket","meaning_zh":"翘辫子","usage_note":"口语","tags":{"list":["idiom","death"]}},
         "publicContributions":[{"id":1,"context_sentence":"He kicked the bucket.","source":{"kind":"youtube","url":"u","title":"t","timestampSec":1.5},"contributed_at":1000}],
         "personalContributions":[]}
        """
        let original = try decode(LookupResponse.self, serverJSON)
        // Encode with OUR encoder, then decode again — must survive.
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(LookupResponse.self, from: data)
        XCTAssertEqual(round.phrase.phraseRaw, "kick the bucket")
        XCTAssertEqual(round.phrase.meaningZh, "翘辫子")
        XCTAssertEqual(round.phrase.tags, ["idiom","death"])      // tags survive wrap/unwrap
        XCTAssertEqual(round.publicContributions.count, 1)
        XCTAssertEqual(round.publicContributions.first?.contextSentence, "He kicked the bucket.")
        XCTAssertEqual(round.publicContributions.first?.source.kind, "youtube")
    }

    func testBrowsePhraseRoundTrips() throws {
        let original = try decode(BrowsePhrase.self,
            #"{"phrase_normalized":"a","phrase_raw":"A","meaning_zh":"甲","usage_note":null,"tags":["x"]}"#)
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(BrowsePhrase.self, from: data)
        XCTAssertEqual(round.phraseNormalized, "a")
        XCTAssertEqual(round.phraseRaw, "A")
        XCTAssertEqual(round.meaningZh, "甲")
        XCTAssertEqual(round.tags, ["x"])
    }

    func testMineItemRoundTrips() throws {
        let original = try decode(MineItem.self,
            #"{"phraseNormalized":"a","phraseRaw":"A","meaningZh":"甲","usageNote":null,"contextSentence":"ctx","source":{"kind":"webpage","url":"u","title":null,"timestampSec":null},"contributedAt":42,"tags":["y"]}"#)
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(MineItem.self, from: data)
        XCTAssertEqual(round.phraseRaw, "A")
        XCTAssertEqual(round.contextSentence, "ctx")
        XCTAssertEqual(round.contributedAt, 42)
        XCTAssertEqual(round.tags, ["y"])
    }
}
```

- [ ] **Step 2: Run to verify failure** — runs in CI (can't compile on Windows). The test won't compile until `LookupResponse`/`BrowsePhrase`/`MineItem` are `Encodable`. Proceed to implement.

- [ ] **Step 3: Change the conformances + add `LookupPhrase.encode`**

In `DTOs.swift`, change these declarations (only the conformance list — bodies unchanged):
- `struct CorpusTag: Decodable, Identifiable {` → `struct CorpusTag: Codable, Identifiable {`
- `struct CorpusSource: Decodable {` → `struct CorpusSource: Codable {`
- `struct BrowsePhrase: Decodable, Identifiable {` → `struct BrowsePhrase: Codable, Identifiable {`
- `struct MineItem: Decodable, Identifiable {` → `struct MineItem: Codable, Identifiable {`
- `struct CorpusContribution: Decodable, Identifiable {` → `struct CorpusContribution: Codable, Identifiable {`
- `struct LookupResponse: Decodable {` → `struct LookupResponse: Codable {`

For `LookupPhrase` (has a custom `init(from:)` for the wrapped tags): change `struct LookupPhrase: Decodable {` → `struct LookupPhrase: Codable {`, make its private `TagWrapper` Codable, and add an `encode(to:)` that writes the SAME wrapped shape the decoder reads (so round-trip works, decoder untouched). The struct currently ends after `init(from:)`; add inside it:
```swift
    private struct TagWrapper: Codable { let list: [String]? }
```
(change `Decodable` → `Codable` on the existing `TagWrapper`), and add this method after `init(from:)`:
```swift
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phraseRaw, forKey: .phraseRaw)
        try c.encodeIfPresent(meaningZh, forKey: .meaningZh)
        try c.encodeIfPresent(usageNote, forKey: .usageNote)
        try c.encode(TagWrapper(list: tags), forKey: .tags) // re-wrap so init(from:) reads it back
    }
```

- [ ] **Step 4: Run the tests** (CI) — expected PASS (tags survive the wrap/unwrap; browse/mine round-trip).

- [ ] **Step 5: Commit (LOCAL)**

```bash
git add whatsub-mobile/Networking/DTOs.swift whatsub-mobileTests/CorpusCodableTests.swift
git commit -m "feat(corpus): make corpus DTOs Codable for on-disk caching"
```

---

## Task 2: `/versions` API

**Files:**
- Modify: `whatsub-mobile/Networking/DTOs.swift` (add `CorpusVersions`)
- Modify: `whatsub-mobile/Networking/WhatsubAPI.swift` (add method)

- [ ] **Step 1: Add the DTO**

In `DTOs.swift`, near the other corpus DTOs, add:
```swift
/// GET /api/corpus/versions → { mine, public }. "public" is a Swift keyword,
/// so it's decoded into `publicVersion`.
struct CorpusVersions: Decodable {
    let mine: Int
    let publicVersion: Int
    enum CodingKeys: String, CodingKey {
        case mine
        case publicVersion = "public"
    }
}
```

- [ ] **Step 2: Add the API method**

In `WhatsubAPI.swift`, in the `// ----- Corpus -----` section (e.g. after `corpusTags`), add:
```swift
    func corpusVersions(token: String) async throws -> CorpusVersions {
        let data = try await get(Endpoints.corpus("versions"), bearer: token)
        return try decode(CorpusVersions.self, from: data)
    }
```

- [ ] **Step 3: Commit (LOCAL)**

```bash
git add whatsub-mobile/Networking/DTOs.swift whatsub-mobile/Networking/WhatsubAPI.swift
git commit -m "feat(corpus): CorpusVersions DTO + WhatsubAPI.corpusVersions (GET /corpus/versions)"
```

---

## Task 3: `CorpusCache` disk store (TDD)

**Files:**
- Create: `whatsub-mobile/Corpus/CorpusCache.swift`
- Test: `whatsub-mobileTests/CorpusCacheTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `whatsub-mobileTests/CorpusCacheTests.swift`:
```swift
import XCTest
@testable import whatsub_mobile

final class CorpusCacheTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("corpuscache_\(UUID().uuidString).json")
    }
    private func phrase(_ id: String) -> BrowsePhrase {
        try! JSONDecoder().decode(BrowsePhrase.self,
            from: Data(#"{"phrase_normalized":"\#(id)","phrase_raw":"\#(id)","meaning_zh":"m","usage_note":null,"tags":[]}"#.utf8))
    }
    private func lookup() -> LookupResponse {
        try! JSONDecoder().decode(LookupResponse.self,
            from: Data(#"{"phrase":{"phrase_raw":"x","meaning_zh":"y","usage_note":null,"tags":{"list":[]}},"publicContributions":[],"personalContributions":[]}"#.utf8))
    }

    func testBrowseRoundTripAndFreshness() {
        let url = tempURL()
        let now = Date()
        do {
            let c = CorpusCache(fileURL: url)
            c.updateVersions(mine: 1, publicVersion: 5)
            c.storeBrowse(items: [phrase("a"), phrase("b")], tags: [], now: now)
            XCTAssertFalse(c.isBrowseStale(now: now))          // just stored at current versions
        }
        let reloaded = CorpusCache(fileURL: url)               // fresh instance reads disk
        reloaded.updateVersions(mine: 1, publicVersion: 5)
        XCTAssertEqual(reloaded.cachedBrowse()?.items.count, 2)
        XCTAssertFalse(reloaded.isBrowseStale(now: now))
        try? FileManager.default.removeItem(at: url)
    }

    func testBrowseStaleOnPublicVersionChangeAndTTL() {
        let url = tempURL(); let now = Date()
        let c = CorpusCache(fileURL: url)
        c.updateVersions(mine: 1, publicVersion: 5)
        c.storeBrowse(items: [phrase("a")], tags: [], now: now)
        c.updateVersions(mine: 1, publicVersion: 6)            // public bumped
        XCTAssertTrue(c.isBrowseStale(now: now))
        c.updateVersions(mine: 1, publicVersion: 5)
        XCTAssertTrue(c.isBrowseStale(now: now.addingTimeInterval(25*3600))) // TTL
        try? FileManager.default.removeItem(at: url)
    }

    func testLookupValidityFollowsBothVersions() {
        let url = tempURL(); let now = Date()
        let c = CorpusCache(fileURL: url)
        c.updateVersions(mine: 2, publicVersion: 3)
        c.storeLookup("p", lookup(), now: now)
        XCTAssertNotNil(c.cachedLookup("p", now: now))
        c.updateVersions(mine: 2, publicVersion: 4)            // public changed
        XCTAssertNil(c.cachedLookup("p", now: now))
        c.updateVersions(mine: 2, publicVersion: 3)
        XCTAssertNil(c.cachedLookup("p", now: now.addingTimeInterval(25*3600))) // TTL
        try? FileManager.default.removeItem(at: url)
    }

    func testLookupLRUCapEvictsOldest() {
        let url = tempURL(); let now = Date()
        let c = CorpusCache(fileURL: url)
        c.updateVersions(mine: 0, publicVersion: 0)
        for i in 0...500 { c.storeLookup("p\(i)", lookup(), now: now) } // 501 stores
        XCTAssertNil(c.cachedLookup("p0", now: now))           // oldest evicted
        XCTAssertNotNil(c.cachedLookup("p500", now: now))      // newest kept
        try? FileManager.default.removeItem(at: url)
    }

    func testCorruptFileStartsEmpty() {
        let url = tempURL()
        try? Data("garbage".utf8).write(to: url)
        let c = CorpusCache(fileURL: url)
        XCTAssertNil(c.cachedBrowse())
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 2: Run to verify failure** (CI) — symbols missing.

- [ ] **Step 3: Implement `CorpusCache.swift`**

```swift
import Foundation

struct CachedList<T: Codable>: Codable {
    var items: [T] = []
    var tags: [CorpusTag] = []
    var fetchedAt: Double = 0   // epoch seconds
    var atMine = -1
    var atPublic = -1
}

struct CachedLookup: Codable {
    var response: LookupResponse
    var fetchedAt: Double
    var atMine: Int
    var atPublic: Int
}

struct CorpusCacheFile: Codable {
    var version = 1
    var mineVersion = -1
    var publicVersion = -1
    var browse = CachedList<BrowsePhrase>()   // public scope, unfiltered
    var mine = CachedList<MineItem>()           // mine scope, unfiltered
    var lookups: [String: CachedLookup] = [:]
    var lookupOrder: [String] = []              // LRU, most-recent at the end
}

/// On-disk corpus cache (`Caches/corpus_cache.json`). Accessed from @MainActor
/// view models. Tagged with the {mine, public} versions each item was fetched
/// under; valid while those match the latest /versions and within the TTL.
final class CorpusCache {
    static let shared = CorpusCache()

    private let fileURL: URL
    private let ttl: TimeInterval
    private let lookupCap = 500
    private var file: CorpusCacheFile

    init(fileURL: URL = CorpusCache.defaultURL, ttl: TimeInterval = 24 * 3600) {
        self.fileURL = fileURL
        self.ttl = ttl
        self.file = CorpusCache.load(fileURL)
    }

    static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("corpus_cache.json")
    }

    var mineVersion: Int { file.mineVersion }
    var publicVersion: Int { file.publicVersion }

    func updateVersions(mine: Int, publicVersion: Int) {
        file.mineVersion = mine
        file.publicVersion = publicVersion
        save()
    }

    // MARK: List
    func cachedBrowse() -> (items: [BrowsePhrase], tags: [CorpusTag])? {
        file.browse.items.isEmpty ? nil : (file.browse.items, file.browse.tags)
    }
    func cachedMine() -> (items: [MineItem], tags: [CorpusTag])? {
        file.mine.items.isEmpty ? nil : (file.mine.items, file.mine.tags)
    }
    func isBrowseStale(now: Date) -> Bool {
        file.browse.items.isEmpty
            || file.browse.atPublic != file.publicVersion
            || now.timeIntervalSince1970 - file.browse.fetchedAt > ttl
    }
    func isMineStale(now: Date) -> Bool {
        file.mine.items.isEmpty
            || file.mine.atMine != file.mineVersion
            || now.timeIntervalSince1970 - file.mine.fetchedAt > ttl
    }
    func storeBrowse(items: [BrowsePhrase], tags: [CorpusTag], now: Date) {
        file.browse = CachedList(items: items, tags: tags,
                                 fetchedAt: now.timeIntervalSince1970,
                                 atMine: file.mineVersion, atPublic: file.publicVersion)
        save()
    }
    func storeMine(items: [MineItem], tags: [CorpusTag], now: Date) {
        file.mine = CachedList(items: items, tags: tags,
                               fetchedAt: now.timeIntervalSince1970,
                               atMine: file.mineVersion, atPublic: file.publicVersion)
        save()
    }

    // MARK: Lookup
    func cachedLookup(_ phrase: String, now: Date) -> LookupResponse? {
        guard let entry = file.lookups[phrase],
              entry.atMine == file.mineVersion,
              entry.atPublic == file.publicVersion,
              now.timeIntervalSince1970 - entry.fetchedAt < ttl
        else { return nil }
        touchLRU(phrase)   // mark most-recently-used
        save()
        return entry.response
    }
    func storeLookup(_ phrase: String, _ response: LookupResponse, now: Date) {
        file.lookups[phrase] = CachedLookup(response: response, fetchedAt: now.timeIntervalSince1970,
                                            atMine: file.mineVersion, atPublic: file.publicVersion)
        touchLRU(phrase)
        while file.lookupOrder.count > lookupCap {
            let evict = file.lookupOrder.removeFirst()
            file.lookups[evict] = nil
        }
        save()
    }

    private func touchLRU(_ phrase: String) {
        file.lookupOrder.removeAll { $0 == phrase }
        file.lookupOrder.append(phrase)
    }

    // MARK: Persistence
    private func save() {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
    private static func load(_ url: URL) -> CorpusCacheFile {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(CorpusCacheFile.self, from: data) else {
            return CorpusCacheFile()
        }
        return f
    }
}
```

- [ ] **Step 4: Run the tests** (CI) — expected PASS.

- [ ] **Step 5: Commit (LOCAL)**

```bash
git add whatsub-mobile/Corpus/CorpusCache.swift whatsub-mobileTests/CorpusCacheTests.swift
git commit -m "feat(corpus): CorpusCache disk store (versions + TTL + LRU)"
```

---

## Task 4: `CorpusViewModel` cache-first list

**Files:**
- Modify: `whatsub-mobile/Corpus/CorpusViewModel.swift`

- [ ] **Step 1: Replace `reload(token:)`**

Replace the existing `reload(token:)` method with:
```swift
    func reload(token: String) async {
        let cache = CorpusCache.shared
        let usingTags = !selectedTags.isEmpty

        // 1. Instant paint from cache (only the unfiltered default view).
        if !usingTags {
            if scope == .publicCorpus, let c = cache.cachedBrowse() { browse = c.items; tags = c.tags }
            else if scope == .mine, let c = cache.cachedMine() { mine = c.items; tags = c.tags }
        }
        let hadCache = !usingTags
            && ((scope == .publicCorpus && !browse.isEmpty) || (scope == .mine && !mine.isEmpty))
        if !hadCache { loading = true }
        errorMessage = nil; licenseLocked = false
        let scopeParam = scope == .publicCorpus ? "public" : "mine"

        do {
            // 2. Refresh versions (small request).
            if let v = try? await WhatsubAPI.shared.corpusVersions(token: token) {
                cache.updateVersions(mine: v.mine, publicVersion: v.publicVersion)
            }
            // 3. Refetch only if stale.
            let stale = usingTags
                || (scope == .publicCorpus && cache.isBrowseStale(now: Date()))
                || (scope == .mine && cache.isMineStale(now: Date()))
            if stale {
                tags = (try? await WhatsubAPI.shared.corpusTags(scope: scopeParam, token: token)) ?? tags
                if scope == .publicCorpus {
                    let items = try await WhatsubAPI.shared.browseCorpus(tags: Array(selectedTags), token: token)
                    browse = items
                    if !usingTags { cache.storeBrowse(items: items, tags: tags, now: Date()) }
                } else {
                    let items = try await WhatsubAPI.shared.mineCorpus(tags: Array(selectedTags), token: token)
                    mine = items
                    if !usingTags { cache.storeMine(items: items, tags: tags, now: Date()) }
                }
            }
        } catch APIError.server(let code, _) where code == 403 {
            licenseLocked = true
        } catch APIError.unauthorized {
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            if !hadCache { errorMessage = e.chinese }   // keep showing cache when offline
        } catch {
            if !hadCache { errorMessage = "加载失败，请下拉重试" }
        }
        loading = false
        loadedOnce = true
    }
```
(`toggleTag`/`switchScope` are unchanged — they call `reload`; with non-empty `selectedTags` the new code always refetches, and `switchScope` resets tags so the cache path applies.)

- [ ] **Step 2: Commit (LOCAL)**

```bash
git add whatsub-mobile/Corpus/CorpusViewModel.swift
git commit -m "feat(corpus): cache-first list + /versions-driven refresh"
```

---

## Task 5: `PhraseDetailViewModel` lookup cache

**Files:**
- Modify: `whatsub-mobile/Corpus/PhraseDetailViewModel.swift`

- [ ] **Step 1: Replace `load(phrase:token:)`**

Replace the existing `load(phrase:token:)` with:
```swift
    func load(phrase: String, token: String) async {
        let cache = CorpusCache.shared
        // 1. Serve from cache when valid — no server call.
        if let cached = cache.cachedLookup(phrase, now: Date()) {
            result = cached
            loading = false
            return
        }
        loading = true; errorMessage = nil
        do {
            let resp = try await WhatsubAPI.shared.lookupPhrase(phrase, token: token)
            result = resp
            if let resp {
                cache.storeLookup(phrase, resp, now: Date())
            } else {
                errorMessage = "未找到该短语的数据"
            }
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败"
        }
        loading = false
    }
```

- [ ] **Step 2: Commit (LOCAL)**

```bash
git add whatsub-mobile/Corpus/PhraseDetailViewModel.swift
git commit -m "feat(corpus): serve phrase lookups from the local cache when fresh"
```

---

## Task 6: Integration — push, CI, merge, TestFlight

- [ ] **Step 1: Push the branch → CI** (first real compile + `CorpusCodableTests`/`CorpusCacheTests`)

```bash
git push -u origin feat/ios-corpus-cache
```
Watch the CI run (`gh run watch <id> --exit-status`). Green = compiles + unit tests pass. If red, fix + re-push.

- [ ] **Step 2: Docs line + merge to main (triggers TestFlight)**

Add a clause to `CLAUDE.md` Status noting the corpus persistent cache. Commit on the branch, then:
```bash
git checkout main
git merge --no-ff feat/ios-corpus-cache -m "Merge corpus persistent cache"
git push origin main
```
The one TestFlight-triggering push. If Archive fails "maximum number of certificates", revoke an old cert at developer.apple.com → Certificates, then `gh run rerun <run-id>`.

- [ ] **Step 3: Manual e2e (TestFlight)**

语料库 first open (fetches) → reopen tab / cold-relaunch app → loads instantly (no spinner), works in airplane mode → tap a phrase twice → 2nd tap instant, no spinner → after a desktop public-corpus publish, next corpus open refetches (version bump). 个人 scope: same instant behavior.

---

## Self-Review

**1. Spec coverage:**
- Caches/corpus_cache.json on disk → Task 3 (`CorpusCache.defaultURL` uses `.cachesDirectory`). ✓
- Cache both scopes + both layers → Task 3 (browse/mine + lookups) + Tasks 4/5. ✓
- `/versions` invalidation, no backend change → Task 2 + Task 4 (updateVersions + isStale). ✓
- 24h TTL → Task 3 (ttl default). ✓
- Lookup LRU cap 500 → Task 3 (`lookupCap` + `touchLRU`/evict) + test. ✓
- cache-first + background refresh → Task 4 (instant paint then version check). ✓
- Only unfiltered list cached → Task 4 (`usingTags` guards store). ✓
- DTO Codable incl. LookupPhrase wrap round-trip → Task 1 + test. ✓
- Offline falls back to cache → Task 4 (`if !hadCache` gates error). ✓
- 403 keeps `licenseLocked` (View gates list on it) → Task 4. ✓
- Corrupt cache → empty → Task 3 (`load` guard) + test. ✓

**2. Placeholder scan:** No TBD/vague steps; every code step has full code. The only prose step is Task 6 Step 3 (manual e2e — inherent).

**3. Type consistency:**
- `CorpusVersions{mine, publicVersion}` — Task 2; consumed in Task 4 (`v.mine`, `v.publicVersion`) + `updateVersions(mine:publicVersion:)` (Task 3). ✓
- `CorpusCache` API — `cachedBrowse/cachedMine -> (items,tags)?`, `isBrowseStale/isMineStale(now:)`, `storeBrowse/storeMine(items:tags:now:)`, `cachedLookup(_:now:)`, `storeLookup(_:_:now:)`, `updateVersions(mine:publicVersion:)`, `mineVersion`/`publicVersion` — defined Task 3, called exactly so in Tasks 4/5 + tests. ✓
- `lookupPhrase` returns `LookupResponse?` → Task 5 stores only when non-nil. ✓
- DTOs Codable (Task 1) are required for `CachedList<BrowsePhrase>`/`CachedList<MineItem>`/`CachedLookup.response: LookupResponse` to compile (Task 3). Order: Task 1 before Task 3. ✓
- No iOS-17 APIs introduced (pure Foundation/Codable + existing SwiftUI). ✓

No gaps found.
