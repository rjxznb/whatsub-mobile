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
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var licenseLocked = false
    @Published var loadedOnce = false

    func reload(token: String) async {
        loading = true; errorMessage = nil; licenseLocked = false
        let scopeParam = scope == .publicCorpus ? "public" : "mine"
        do {
            // Fetch tags first, then the list (sequential — simpler, corpus isn't perf-critical).
            tags = (try? await WhatsubAPI.shared.corpusTags(scope: scopeParam, token: token)) ?? []
            if scope == .publicCorpus {
                browse = try await WhatsubAPI.shared.browseCorpus(tags: Array(selectedTags), token: token)
            } else {
                mine = try await WhatsubAPI.shared.mineCorpus(tags: Array(selectedTags), token: token)
            }
        } catch APIError.server(let code, _) where code == 403 {
            licenseLocked = true
        } catch APIError.unauthorized {
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败，请下拉重试"
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
