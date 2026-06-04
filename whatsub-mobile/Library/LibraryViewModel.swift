import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryListItem] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var loadedOnce = false

    func delete(_ id: String, token: String) async {
        do {
            try await WhatsubAPI.shared.deleteLibraryEntry(id: id, token: token)
            entries.removeAll { $0.id == id }
            // Also drop any local drafts staged from this video — they were
            // anchored to this video's context (timestamps + transcript
            // sentences) and can't be navigated back to once the source is
            // gone. Phrases ALREADY synced to the cloud corpus are
            // unaffected — they live independently from this point on.
            PendingPhraseStore.shared.removeAll(entryId: id)
        } catch {
            errorMessage = "删除失败，请稍后重试"
        }
    }

    func load(token: String) async {
        loading = true
        errorMessage = nil
        do {
            entries = try await WhatsubAPI.shared.listLibrary(token: token)
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
}
