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
