import Foundation
import SwiftUI

enum CorpusScope: String, CaseIterable, Identifiable {
    case publicCorpus, mine
    var id: String { rawValue }
}

@MainActor
final class CorpusViewModel: ObservableObject {
    @Published var scope: CorpusScope = .mine   // mine has data; public may be empty/locked
    @Published var tags: [CorpusTag] = []
    @Published var selectedTags: Set<String> = []
    @Published var browse: [BrowsePhrase] = []
    @Published var mine: [MineItem] = []
    @Published var mineTotal: Int = 0
    /// Server-authoritative personal-corpus quota (used/limit). nil until fetched
    /// or on failure → CorpusView falls back to the local count + iosSubActive guess.
    @Published var corpusQuota: CorpusQuota?
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var licenseLocked = false
    @Published var loadedOnce = false

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
            // Personal-corpus quota (only shown in 我的). Best-effort + server-authoritative
            // so it reflects cross-platform (Alipay) subscriptions, not just iosSubActive.
            if scope == .mine {
                corpusQuota = try? await WhatsubAPI.shared.corpusQuota(token: token)
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
                    let resp = try await WhatsubAPI.shared.mineCorpus(tags: Array(selectedTags), token: token)
                    mine = resp.items
                    mineTotal = resp.total
                    if !usingTags { cache.storeMine(items: resp.items, tags: tags, now: Date()) }
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
