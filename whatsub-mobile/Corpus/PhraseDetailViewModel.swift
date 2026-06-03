import Foundation
import SwiftUI

@MainActor
final class PhraseDetailViewModel: ObservableObject {
    @Published var result: LookupResponse?
    @Published var loading = true
    @Published var errorMessage: String?

    /// Instances to show = personal first, then public, deduped by content.
    ///
    /// Admin "添加到公共" dual-writes (one personal row + one curator row at
    /// the same `Date.now()`) would otherwise render as two identical cards.
    /// Row `id` differs, so we fingerprint by `(contextSentence, source.url,
    /// contributedAt)` — same save event ⇒ exact-equal across all three.
    /// Personal is kept on tie so a user's own edits beat the curated copy.
    var instances: [CorpusContribution] {
        guard let r = result else { return [] }
        let combined = r.personalContributions + r.publicContributions
        var seen = Set<String>()
        return combined.filter { c in
            let key = "\(c.contextSentence)|\(c.source.url ?? "")|\(c.contributedAt)"
            return seen.insert(key).inserted
        }
    }

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
}
