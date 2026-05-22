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
