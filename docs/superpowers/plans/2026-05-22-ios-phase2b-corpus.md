# Plan 2 Phase 2b: iOS Corpus (公共/我的语料库 + phrase detail)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** The 语料库 tab (tab 1) lets the user browse the public corpus (license-gated, curator phrases) and their personal corpus (their saved phrases), filtered by tag chips. Tapping a phrase opens a detail view: phrase + meaning + usage + tags + instances (例句出处). For YouTube-sourced instances, an embedded player seeks to the timestamp; webpage/pdf instances open the source URL in Safari.

**Architecture:** `WhatsubAPI` gains corpus methods. The corpus API has THREE different wire formats (verified against prod): `/browse` phrases are **snake_case** + carry no per-instance source; `/mine` items are **camelCase** + instance-level (one row per save) with a `source`; `/lookup?withScope=true` returns a snake_case `phrase` (with `tags` wrapped as `{list:[...]}`) + `publicContributions` + `personalContributions` (snake_case rows whose `source` JSONB is camelCase). DTOs use explicit `CodingKeys` per type. `CorpusSource.kind ∈ {youtube, webpage, pdf, curator}`; only `youtube` carries `timestampSec`. Reuse `YouTubeEmbedView` (add an optional `startSeconds` so it begins at the instance timestamp).

**Tech Stack:** SwiftUI · SafariServices (SFSafariViewController) · reuse YouTubeEmbedView · XCTest.

**Working dir:** `C:\Users\renjx\Desktop\whatsub-mobile`.

**Backend (live, verified):**
- `GET /api/corpus/tags?scope=public|mine` → `{tags:[{tag,count}]}`. public needs active license (403 `license_required`); mine needs only session.
- `GET /api/corpus/browse?tags=a,b&limit=20&offset=0` → `{phrases:[...],total}`. Needs session + active license (403 if not). phrase: `{phrase_normalized, phrase_raw, contribution_count, first_seen_at, last_seen_at, meaning_zh, usage_note, tags:[...]}`.
- `GET /api/corpus/mine?tags=a,b&page=1&pageSize=50` → `{items:[...],total,page,pageSize}`. Session only. item: `{phraseNormalized, phraseRaw, meaningZh, usageNote, contextSentence, source:{kind,url,title?,timestampSec?}, contributedAt, tags:[...]}`.
- `GET /api/corpus/lookup?phrase=X&withScope=true` → `{phrase:{...snake..., tags:{list:[...]}}, publicContributions:[contrib], personalContributions:[contrib]}` or `{ok:false,reason:"no_data"}` (404). contrib: `{id, phrase_normalized, context_sentence, source:{kind,url,title?,timestampSec?}, contributor_id, contributed_at, meaning_zh, usage_note, tags:[...], flagged, flag_count, hidden}`. publicContributions is `[]` without a license.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `whatsub-mobile/Networking/DTOs.swift` | + corpus DTOs (CorpusTag, CorpusSource, BrowsePhrase, MineItem, CorpusContribution, LookupResponse) | Modify |
| `whatsub-mobile/Networking/WhatsubAPI.swift` | + corpusTags / browseCorpus / mineCorpus / lookupPhrase | Modify |
| `whatsub-mobile/Components/YouTubeEmbedView.swift` | + optional `startSeconds` playerVar | Modify |
| `whatsub-mobile/Components/SafariView.swift` | SFSafariViewController wrapper | Create |
| `whatsub-mobile/Corpus/YouTubeID.swift` | extract videoId from a YouTube URL | Create |
| `whatsub-mobile/Corpus/CorpusViewModel.swift` | scope + tags + lists state | Create |
| `whatsub-mobile/Corpus/CorpusView.swift` | segmented + tag chips + two lists (replaces CorpusPlaceholderView) | Create |
| `whatsub-mobile/Corpus/PhraseDetailViewModel.swift` | lookup + instance state | Create |
| `whatsub-mobile/Corpus/PhraseDetailView.swift` | header + instances + youtube embed / safari | Create |
| `whatsub-mobile/App/WhatsubMobileApp.swift` | tab 1 → CorpusView | Modify |
| `whatsub-mobile/Views/CorpusPlaceholderView.swift` | delete | Delete |
| `whatsub-mobileTests/CorpusDecodeTests.swift` | decode browse(snake)/mine(camel)/lookup | Create |
| `whatsub-mobileTests/YouTubeIDTests.swift` | id extraction cases | Create |

---

## Pre-flight

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git checkout main && git pull
git checkout -b feat/ios-phase2b-corpus
```
No local Swift compile (no Mac) — CI validates after push.

---

### Task 1: Corpus DTOs

**Files:** Modify `whatsub-mobile/Networking/DTOs.swift` (append)

- [ ] **Step 1: Append**

```swift

// ----- Corpus -----

struct CorpusTag: Decodable, Identifiable {
    var id: String { tag }
    let tag: String
    let count: Int
}
struct CorpusTagsResponse: Decodable { let tags: [CorpusTag] }

/// A contribution's source. JSONB written by the plugin — camelCase on the wire
/// in BOTH /mine and /lookup. Only `youtube` carries `timestampSec`.
struct CorpusSource: Decodable {
    let kind: String   // youtube | webpage | pdf | curator
    let url: String
    let title: String?
    let timestampSec: Double?
}

/// /browse phrase — snake_case, phrase-level (no per-instance source).
struct BrowsePhrase: Decodable, Identifiable {
    var id: String { phraseNormalized }
    let phraseNormalized: String
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let tags: [String]
    enum CodingKeys: String, CodingKey {
        case phraseNormalized = "phrase_normalized"
        case phraseRaw = "phrase_raw"
        case meaningZh = "meaning_zh"
        case usageNote = "usage_note"
        case tags
    }
}
struct BrowseResponse: Decodable { let phrases: [BrowsePhrase]; let total: Int }

/// /mine item — camelCase, instance-level (one row per save).
struct MineItem: Decodable, Identifiable {
    let phraseNormalized: String
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let contextSentence: String
    let source: CorpusSource
    let contributedAt: Int64
    let tags: [String]
    var id: String { "\(phraseNormalized)#\(contributedAt)" }
}
struct MineResponse: Decodable { let items: [MineItem]; let total: Int }

/// /lookup contribution — snake_case row; its `source` JSONB is camelCase.
struct CorpusContribution: Decodable, Identifiable {
    let id: Int
    let contextSentence: String
    let source: CorpusSource
    let contributedAt: Int64
    enum CodingKeys: String, CodingKey {
        case id
        case contextSentence = "context_sentence"
        case source
        case contributedAt = "contributed_at"
    }
}

/// /lookup phrase — snake_case; `tags` arrives wrapped as `{ list: [...] }`.
struct LookupPhrase: Decodable {
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let tags: [String]
    enum CodingKeys: String, CodingKey {
        case phraseRaw = "phrase_raw"
        case meaningZh = "meaning_zh"
        case usageNote = "usage_note"
        case tags
    }
    private struct TagWrapper: Decodable { let list: [String]? }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phraseRaw = try c.decodeIfPresent(String.self, forKey: .phraseRaw) ?? ""
        meaningZh = try c.decodeIfPresent(String.self, forKey: .meaningZh)
        usageNote = try c.decodeIfPresent(String.self, forKey: .usageNote)
        let wrapped = try c.decodeIfPresent(TagWrapper.self, forKey: .tags)
        tags = wrapped?.list ?? []
    }
}
struct LookupResponse: Decodable {
    let phrase: LookupPhrase
    let publicContributions: [CorpusContribution]
    let personalContributions: [CorpusContribution]
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Networking/DTOs.swift
git commit -m "feat(ios/corpus): DTOs (browse snake / mine camel / lookup + tags + source)"
```

---

### Task 2: WhatsubAPI corpus methods

**Files:** Modify `whatsub-mobile/Networking/WhatsubAPI.swift`

- [ ] **Step 1: Add after the library methods**

```swift
    // ----- Corpus -----

    /// scope = "public" (needs license) or "mine" (session only).
    func corpusTags(scope: String, token: String) async throws -> [CorpusTag] {
        let data = try await get(Endpoints.corpus("tags?scope=\(scope)"), bearer: token)
        return try decode(CorpusTagsResponse.self, from: data).tags
    }

    func browseCorpus(tags: [String], token: String) async throws -> [BrowsePhrase] {
        var path = "browse?limit=100"
        if !tags.isEmpty {
            let joined = tags.joined(separator: ",")
            path += "&tags=\(joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined)"
        }
        let data = try await get(Endpoints.corpus(path), bearer: token)
        return try decode(BrowseResponse.self, from: data).phrases
    }

    func mineCorpus(tags: [String], token: String) async throws -> [MineItem] {
        var path = "mine?pageSize=100"
        if !tags.isEmpty {
            let joined = tags.joined(separator: ",")
            path += "&tags=\(joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined)"
        }
        let data = try await get(Endpoints.corpus(path), bearer: token)
        return try decode(MineResponse.self, from: data).items
    }

    /// Returns nil when the backend reports no_data (404).
    func lookupPhrase(_ phrase: String, token: String) async throws -> LookupResponse? {
        let enc = phrase.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? phrase
        do {
            let data = try await get(Endpoints.corpus("lookup?phrase=\(enc)&withScope=true"), bearer: token)
            return try decode(LookupResponse.self, from: data)
        } catch APIError.notFound {
            return nil
        }
    }
```

- [ ] **Step 2: Verify `Endpoints.corpus(...)` exists.** If `Endpoints` has `corpusBase` but no `corpus(_:)` helper, add one mirroring `library(_:)`:
```swift
    static func corpus(_ path: String) -> URL { URL(string: "\(corpusBase)/\(path)")! }
```
Check `whatsub-mobile/Networking/Endpoints.swift`; `corpusBase` should be `https://whatsub.eversay.cc/api/corpus`.

- [ ] **Step 3: Verify `APIError.notFound` exists** (for the 404 → nil path). If `APIError` only maps 404 to a generic case, add a `.notFound` case + map status 404 to it in the HTTP layer. Check `APIError.swift` + the `get`/status-handling code. (Library's `entry/:id` already hits 404 paths — confirm how it's surfaced; reuse that.)

- [ ] **Step 4: Commit**
```bash
git add whatsub-mobile/Networking/WhatsubAPI.swift whatsub-mobile/Networking/Endpoints.swift whatsub-mobile/Networking/APIError.swift
git commit -m "feat(ios/corpus): WhatsubAPI tags/browse/mine/lookup"
```

---

### Task 3: YouTubeID extractor (TDD)

**Files:** Create `whatsub-mobile/Corpus/YouTubeID.swift` + `whatsub-mobileTests/YouTubeIDTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import whatsub_mobile

final class YouTubeIDTests: XCTestCase {
    func testWatchURL() {
        XCTAssertEqual(extractYouTubeID("https://www.youtube.com/watch?v=ECXAFUmdJkI"), "ECXAFUmdJkI")
    }
    func testWatchURLWithExtraParams() {
        XCTAssertEqual(extractYouTubeID("https://www.youtube.com/watch?v=ECXAFUmdJkI&t=90s&list=xx"), "ECXAFUmdJkI")
    }
    func testShortURL() {
        XCTAssertEqual(extractYouTubeID("https://youtu.be/ECXAFUmdJkI?t=12"), "ECXAFUmdJkI")
    }
    func testNonYouTube() {
        XCTAssertNil(extractYouTubeID("https://example.com/page"))
    }
}
```

- [ ] **Step 2: Implement `YouTubeID.swift`**

```swift
import Foundation

/// Extract the 11-char video id from a YouTube watch / youtu.be URL.
/// Returns nil for non-YouTube URLs.
func extractYouTubeID(_ urlString: String) -> String? {
    guard let comps = URLComponents(string: urlString), let host = comps.host else { return nil }
    if host.contains("youtu.be") {
        let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }
    if host.contains("youtube.com") {
        return comps.queryItems?.first(where: { $0.name == "v" })?.value
    }
    return nil
}
```

- [ ] **Step 3: Commit**
```bash
git add whatsub-mobile/Corpus/YouTubeID.swift whatsub-mobileTests/YouTubeIDTests.swift
git commit -m "feat(ios/corpus): YouTube id extractor + TDD"
```

---

### Task 4: YouTubeEmbedView startSeconds + SafariView

**Files:** Modify `whatsub-mobile/Components/YouTubeEmbedView.swift`; Create `whatsub-mobile/Components/SafariView.swift`

- [ ] **Step 1: Add `startSeconds` to YouTubeEmbedView.** Add a stored property `var startSeconds: Double? = nil` (after `videoId`). In `html(videoId:)`, change it to `html(videoId:startSeconds:)` and inject the start playerVar:
```swift
    func makeUIView(context: Context) -> WKWebView {
        // ... unchanged setup ...
        webView.loadHTMLString(Self.html(videoId: videoId, startSeconds: startSeconds), baseURL: URL(string: "https://www.youtube-nocookie.com"))
        // ...
    }
```
In the HTML's `playerVars`, add `start` when present. Change the playerVars line to build dynamically:
```swift
    private static func html(videoId: String, startSeconds: Double?) -> String {
        let startVar = startSeconds.map { ", start: \(Int($0))" } ?? ""
        return """
        ... playerVars: { playsinline: 1, modestbranding: 1, rel: 0\(startVar) }, ...
        """
    }
```
(Library callers omit `startSeconds` → default nil → no `start` → unchanged behavior. The `onReady:`/`onTime:` params are unchanged.)

- [ ] **Step 2: SafariView.swift**
```swift
import SwiftUI
import SafariServices

/// Opens a URL in an in-app Safari sheet (SFSafariViewController).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
```

- [ ] **Step 3: Commit**
```bash
git add whatsub-mobile/Components/YouTubeEmbedView.swift whatsub-mobile/Components/SafariView.swift
git commit -m "feat(ios/corpus): YouTubeEmbedView startSeconds + SafariView"
```

---

### Task 5: CorpusViewModel + CorpusView (replaces placeholder)

**Files:** Create `whatsub-mobile/Corpus/CorpusViewModel.swift` + `whatsub-mobile/Corpus/CorpusView.swift`

- [ ] **Step 1: CorpusViewModel.swift**

```swift
import Foundation
import SwiftUI

enum CorpusScope: String, CaseIterable, Identifiable { case publicCorpus, mine; var id: String { rawValue } }

@MainActor
final class CorpusViewModel: ObservableObject {
    @Published var scope: CorpusScope = .mine   // mine has data; public may be empty/locked
    @Published var tags: [CorpusTag] = []
    @Published var selectedTags: Set<String> = []
    @Published var browse: [BrowsePhrase] = []
    @Published var mine: [MineItem] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var licenseLocked = false

    func reload(token: String) async {
        loading = true; errorMessage = nil; licenseLocked = false
        let scopeParam = scope == .publicCorpus ? "public" : "mine"
        do {
            async let tagsTask = WhatsubAPI.shared.corpusTags(scope: scopeParam, token: token)
            if scope == .publicCorpus {
                browse = try await WhatsubAPI.shared.browseCorpus(tags: Array(selectedTags), token: token)
            } else {
                mine = try await WhatsubAPI.shared.mineCorpus(tags: Array(selectedTags), token: token)
            }
            tags = (try? await tagsTask) ?? []
        } catch APIError.forbidden {
            licenseLocked = true
        } catch APIError.unauthorized {
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败，请下拉重试"
        }
        loading = false
    }

    func toggleTag(_ tag: String, token: String) async {
        if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
        await reload(token: token)
    }

    func switchScope(_ s: CorpusScope, token: String) async {
        guard s != scope else { return }
        scope = s; selectedTags = []
        await reload(token: token)
    }
}
```
(Note: `APIError.forbidden` is the 403 license case. Verify it exists in `APIError.swift`; if 403 isn't mapped, add a `.forbidden` case + map status 403. The corpus public scope returns 403 `license_required`.)

- [ ] **Step 2: CorpusView.swift**

```swift
import SwiftUI

struct CorpusView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = CorpusViewModel()

    private var token: String? { appState.session?.sessionToken }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("语料库")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.whatsubInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)

                Picker("", selection: Binding(
                    get: { vm.scope },
                    set: { s in Task { if let t = token { await vm.switchScope(s, token: t) } } }
                )) {
                    Text("公共").tag(CorpusScope.publicCorpus)
                    Text("我的").tag(CorpusScope.mine)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 8)

                if !vm.tags.isEmpty { tagChips }

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.whatsubBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { phrase in
                PhraseDetailView(phrase: phrase)
            }
            .task { if let t = token, vm.mine.isEmpty && vm.browse.isEmpty { await vm.reload(token: t) } }
            .refreshable { if let t = token { await vm.reload(token: t) } }
        }
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.tags) { t in
                    let on = vm.selectedTags.contains(t.tag)
                    Text("\(t.tag) \(t.count)")
                        .font(.caption).fontWeight(on ? .semibold : .regular)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(on ? Color.whatsubAccent.opacity(0.25) : Color.whatsubBgElev, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.whatsubAccent : .clear, lineWidth: 1))
                        .foregroundStyle(on ? .whatsubAccent : .whatsubInkSoft)
                        .onTapGesture { if let tok = token { Task { await vm.toggleTag(t.tag, token: tok) } } }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.browse.isEmpty && vm.mine.isEmpty {
            Spacer(); ProgressView().tint(.whatsubAccent); Spacer()
        } else if vm.licenseLocked {
            centered(icon: "lock", title: "公共语料库需会员",
                     sub: "购买 whatSub 会员后即可浏览公共语料库；\n「我的」语料库始终可用")
        } else if let err = vm.errorMessage {
            centered(icon: "exclamationmark.triangle", title: err, sub: "下拉重试")
        } else if vm.scope == .publicCorpus {
            if vm.browse.isEmpty {
                centered(icon: "books.vertical", title: "公共语料库暂无内容", sub: "管理员添加后这里会出现")
            } else {
                List(vm.browse) { p in
                    NavigationLink(value: p.phraseNormalized) {
                        PhraseRow(raw: p.phraseRaw, meaning: p.meaningZh, sub: nil, tags: p.tags)
                    }.listRowBackground(Color.whatsubBgElev)
                }.scrollContentBackground(.hidden)
            }
        } else {
            if vm.mine.isEmpty {
                centered(icon: "bookmark", title: "还没有收藏的短语", sub: "用 whatSub 插件在网页/视频里保存短语，\n这里就能看到")
            } else {
                List(vm.mine) { m in
                    NavigationLink(value: m.phraseNormalized) {
                        PhraseRow(raw: m.phraseRaw, meaning: m.meaningZh, sub: m.contextSentence, tags: m.tags)
                    }.listRowBackground(Color.whatsubBgElev)
                }.scrollContentBackground(.hidden)
            }
        }
    }

    private func centered(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.whatsubAccent)
            Text(title).font(.headline).foregroundStyle(.whatsubInk)
            Text(sub).font(.footnote).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
            Spacer()
        }.padding(32)
    }
}

private struct PhraseRow: View {
    let raw: String
    let meaning: String?
    let sub: String?
    let tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(raw).font(.system(size: 17, weight: .semibold)).foregroundStyle(.whatsubInk)
            if let m = meaning, !m.isEmpty {
                Text(m).font(.subheadline).foregroundStyle(.whatsubInkSoft).lineLimit(2)
            }
            if let s = sub, !s.isEmpty {
                Text(s).font(.caption).foregroundStyle(.whatsubInkMuted).lineLimit(1)
            }
            if !tags.isEmpty {
                Text(tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2).foregroundStyle(.whatsubInkFaint)
            }
        }.padding(.vertical, 4)
    }
}
```

- [ ] **Step 3: Commit**
```bash
git add whatsub-mobile/Corpus/CorpusViewModel.swift whatsub-mobile/Corpus/CorpusView.swift
git commit -m "feat(ios/corpus): CorpusView — scope toggle + tag chips + lists + states"
```

---

### Task 6: PhraseDetailViewModel + PhraseDetailView

**Files:** Create `whatsub-mobile/Corpus/PhraseDetailViewModel.swift` + `whatsub-mobile/Corpus/PhraseDetailView.swift`

- [ ] **Step 1: PhraseDetailViewModel.swift**

```swift
import Foundation
import SwiftUI

@MainActor
final class PhraseDetailViewModel: ObservableObject {
    @Published var result: LookupResponse?
    @Published var loading = true
    @Published var errorMessage: String?

    /// Instances to show = personal first, then public (deduped by id).
    var instances: [CorpusContribution] {
        guard let r = result else { return [] }
        return r.personalContributions + r.publicContributions
    }

    func load(phrase: String, token: String) async {
        loading = true; errorMessage = nil
        do {
            result = try await WhatsubAPI.shared.lookupPhrase(phrase, token: token)
            if result == nil { errorMessage = "未找到该短语的数据" }
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败"
        }
        loading = false
    }
}
```

- [ ] **Step 2: PhraseDetailView.swift**

```swift
import SwiftUI

struct PhraseDetailView: View {
    let phrase: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = PhraseDetailViewModel()
    @State private var safariURL: URL?
    @State private var playing: CorpusContribution?

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            if vm.loading {
                ProgressView().tint(.whatsubAccent)
            } else if let err = vm.errorMessage {
                Text(err).foregroundStyle(.whatsubInkMuted).padding()
            } else if let r = vm.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(r.phrase)
                        if !vm.instances.isEmpty {
                            Text("例句出处").font(.headline).foregroundStyle(.whatsubInk)
                            ForEach(vm.instances) { c in instanceCard(c) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(phrase)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let token = appState.session?.sessionToken else { return }
            await vm.load(phrase: phrase, token: token)
        }
        .sheet(item: $safariURL) { url in SafariView(url: url) }
    }

    private func header(_ p: LookupPhrase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.phraseRaw).font(.system(size: 28, weight: .bold)).foregroundStyle(.whatsubInk)
            if let m = p.meaningZh, !m.isEmpty {
                Text(m).font(.title3).foregroundStyle(.whatsubAccent)
            }
            if let u = p.usageNote, !u.isEmpty {
                Text(u).font(.callout).foregroundStyle(.whatsubInkSoft)
            }
            if !p.tags.isEmpty {
                Text(p.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.whatsubInkFaint)
            }
        }
    }

    @ViewBuilder
    private func instanceCard(_ c: CorpusContribution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.contextSentence).font(.body).foregroundStyle(.whatsubInk)
            if let t = c.source.title, !t.isEmpty {
                Text(t).font(.caption).foregroundStyle(.whatsubInkMuted).lineLimit(1)
            }
            // YouTube source with a timestamp → inline embed seeked to it.
            if c.source.kind == "youtube",
               let vid = extractYouTubeID(c.source.url) {
                if playing?.id == c.id {
                    YouTubeEmbedView(videoId: vid, startSeconds: c.source.timestampSec, seek: nil, onReady: {}, onTime: { _ in })
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .background(Color.black)
                } else {
                    sourceButton(icon: "play.circle.fill",
                                 label: c.source.timestampSec.map { "▶ 在 \(mmss($0)) 播放" } ?? "▶ 播放") {
                        playing = c
                    }
                }
            } else {
                // webpage / pdf / curator → open the source URL in Safari.
                sourceButton(icon: "safari", label: "打开来源") {
                    if let u = URL(string: c.source.url) { safariURL = u }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sourceButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.whatsubAccent)
        }
    }

    private func mmss(_ sec: Double) -> String {
        let s = Int(sec)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }
```
(Note: if `URL: Identifiable` is already declared elsewhere in the project, drop the extension here to avoid a duplicate-conformance error. Check before adding.)

- [ ] **Step 3: Commit**
```bash
git add whatsub-mobile/Corpus/PhraseDetailViewModel.swift whatsub-mobile/Corpus/PhraseDetailView.swift
git commit -m "feat(ios/corpus): PhraseDetailView — header + instances + youtube embed / safari"
```

---

### Task 7: Wire CorpusView into tab 1

**Files:** Modify `whatsub-mobile/App/WhatsubMobileApp.swift`; Delete `whatsub-mobile/Views/CorpusPlaceholderView.swift`

- [ ] **Step 1:** Replace `CorpusPlaceholderView()` with `CorpusView()` in the TabView (tab tag 1, the 语料库 tab). The tab's `.tabItem` label/tag stay unchanged.
- [ ] **Step 2:** `rm whatsub-mobile/Views/CorpusPlaceholderView.swift`
- [ ] **Step 3: Commit**
```bash
git add whatsub-mobile/App/WhatsubMobileApp.swift whatsub-mobile/Views/CorpusPlaceholderView.swift
git commit -m "feat(ios/corpus): tab 1 uses real CorpusView"
```

---

### Task 8: Decode tests

**Files:** Create `whatsub-mobileTests/CorpusDecodeTests.swift`

- [ ] **Step 1:** Tests covering the three wire formats:

```swift
import XCTest
@testable import whatsub_mobile

final class CorpusDecodeTests: XCTestCase {
    func testBrowseSnakeCase() throws {
        let json = #"{"phrases":[{"phrase_normalized":"save up","phrase_raw":"save up","contribution_count":3,"first_seen_at":1,"last_seen_at":2,"meaning_zh":"攒钱","usage_note":"存钱","tags":["money"]}],"total":1}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(BrowseResponse.self, from: json)
        XCTAssertEqual(r.phrases.first?.phraseRaw, "save up")
        XCTAssertEqual(r.phrases.first?.meaningZh, "攒钱")
        XCTAssertEqual(r.phrases.first?.tags, ["money"])
    }

    func testMineCamelCaseWithSource() throws {
        let json = #"{"items":[{"phraseNormalized":"moe","phraseRaw":"MoE","meaningZh":"专家混合","usageNote":"用法","contextSentence":"... MoE ...","source":{"url":"https://x.com","kind":"webpage","title":"X"},"contributedAt":1779360308213,"tags":["AI"]}],"total":1}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(MineResponse.self, from: json)
        XCTAssertEqual(r.items.first?.phraseRaw, "MoE")
        XCTAssertEqual(r.items.first?.source.kind, "webpage")
        XCTAssertNil(r.items.first?.source.timestampSec)
        XCTAssertEqual(r.items.first?.contributedAt, 1779360308213)
    }

    func testLookupWithWrappedTagsAndYouTubeSource() throws {
        let json = #"""
        {"phrase":{"phrase_raw":"save up","meaning_zh":"攒钱","usage_note":"存钱","tags":{"list":["money"]}},
         "publicContributions":[],
         "personalContributions":[{"id":7,"phrase_normalized":"save up","context_sentence":"I save up.","source":{"kind":"youtube","url":"https://www.youtube.com/watch?v=abc12345678","timestampSec":42},"contributor_id":"u","contributed_at":99,"meaning_zh":null,"usage_note":null,"tags":[],"flagged":false,"flag_count":0,"hidden":false}]}
        """#.data(using: .utf8)!
        let r = try JSONDecoder().decode(LookupResponse.self, from: json)
        XCTAssertEqual(r.phrase.tags, ["money"])   // unwrapped from {list:[...]}
        let c = r.personalContributions.first!
        XCTAssertEqual(c.id, 7)
        XCTAssertEqual(c.source.kind, "youtube")
        XCTAssertEqual(c.source.timestampSec, 42)
        XCTAssertEqual(extractYouTubeID(c.source.url), "abc12345678")
    }
}
```

- [ ] **Step 2: Commit**
```bash
git add whatsub-mobileTests/CorpusDecodeTests.swift
git commit -m "test(ios/corpus): decode browse(snake)/mine(camel)/lookup(wrapped tags)"
```

---

### Task 9: Push branch + CI

- [ ] **Step 1: Push**
```bash
git push -u origin feat/ios-phase2b-corpus
```
- [ ] **Step 2: Watch CI**
```bash
gh run watch $(gh run list --repo rjxznb/whatsub-mobile --branch feat/ios-phase2b-corpus --limit 1 --json databaseId -q '.[0].databaseId') --repo rjxznb/whatsub-mobile --exit-status
```
Likely watch-outs: `APIError.forbidden`/`.notFound` cases (add if missing — Task 2/5 notes), `Endpoints.corpus(_:)` helper, `URL: Identifiable` duplicate conformance, iOS-16 single-param `.onChange` (none used here), segmented `Picker` binding. Fix + re-push until green.

---

### Task 10: Merge + TestFlight (PAUSE — get user authorization)

**STOP. Get explicit user authorization before merging to main (triggers TestFlight).**

- [ ] **Step 1: Merge + push + delete branch** (standard pattern).
- [ ] **Step 2: Watch testflight.yml.**
- [ ] **Step 3: User installs + tests:**
  1. 语料库 tab → 我的 → sees saved phrases (MoE etc.) + tag chips (AI/job/Economy/housing)
  2. Tap a tag → list filters (AND)
  3. Tap a phrase → detail: meaning + usage + tags + 例句出处
  4. webpage instance → 打开来源 → Safari sheet opens the source
  5. (if a youtube instance exists) ▶ 在 M:SS 播放 → inline player seeks to the timestamp (VPN needed)
  6. 公共 tab → empty state ("公共语料库暂无内容") since curator corpus is empty; (no 403 since user has license)

---

## Done criteria

- 语料库 tab: 公共/我的 toggle, tag-chip AND filter, phrase lists, empty/locked/error states
- Phrase detail: meaning + usage + tags + instances; youtube instance embeds + seeks; webpage/pdf opens in Safari
- Decode tests green for all three wire formats (snake/camel/wrapped-tags); CI green; TestFlight build works
- This completes the iOS v1 consumer feature set (login + Library + Corpus).

## Notes
- Three wire formats are intentional (verified against prod), not a bug: /browse snake, /mine camel, /lookup snake+wrapped-tags. DTOs use explicit CodingKeys.
- Public corpus is empty now → 公共 tab shows an empty state. The user has a license, so no 403; the `licenseLocked` path is defensive for non-paying users.
- Corpus instances are mostly webpages (the plugin captures from any page), so most ▶ are "打开来源"; the inline YouTube embed only applies to `kind:youtube` instances with a `timestampSec`.
