import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryListItem] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var loadedOnce = false
    /// Bumped on every successful list reload. Threaded into `RemoteImage`
    /// rows so pull-to-refresh also forces a fresh thumbnail fetch — the
    /// stock `AsyncImage` we used to use here re-rendered the same URL
    /// from cache and never noticed a network state change (VPN flip
    /// → poisoned URLCache + iOS DNS). See `RemoteImage.swift`.
    @Published var thumbRefreshNonce: Int = 0

    /// Injectable for tests; production uses the shared on-disk cache.
    private let cache: LibraryCache

    init(cache: LibraryCache = .shared) {
        self.cache = cache
    }

    func delete(_ id: String, token: String) async {
        do {
            try await WhatsubAPI.shared.deleteLibraryEntry(id: id, token: token)
            entries.removeAll { $0.id == id }
            // The cached list still contains the row (and the cached server
            // version predates the delete) — drop it so a cold start can't
            // resurrect the removed video.
            cache.clear()
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

    /// Cache-first load (2026-07-05, mirror of the corpus flow):
    ///   1. First run paints the cached list instantly (cold start, offline).
    ///   2. GET /version (one number). Fingerprint matches cache within TTL
    ///      → done, the full /list round-trip is skipped entirely.
    ///   3. Otherwise fetch /list and store it under the server version.
    /// A network failure keeps whatever is on screen (cache) — the error
    /// page only shows when there's nothing to render (view checks
    /// entries.isEmpty), so errorMessage stays harmless here.
    func load(token: String, email: String) async {
        // Instant paint before any network. Only on the first load — later
        // reloads already have entries on screen.
        if !loadedOnce, entries.isEmpty, let cached = cache.cached(for: email) {
            entries = cached.entries
        }
        loading = true
        errorMessage = nil
        do {
            // Version probe is best-effort: any failure (old backend without
            // /version, transient network) falls back to the full fetch.
            let serverVersion = try? await WhatsubAPI.shared.libraryVersion(token: token)
            if let v = serverVersion,
               cache.isFresh(for: email, serverVersion: v, now: Date()),
               let cached = cache.cached(for: email) {
                entries = cached.entries
            } else {
                entries = try await WhatsubAPI.shared.listLibrary(token: token)
                if let v = serverVersion {
                    cache.store(entries: entries, version: v, for: email, now: Date())
                }
            }
        } catch APIError.unauthorized {
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败，请下拉重试"
        }
        loading = false
        loadedOnce = true
        thumbRefreshNonce &+= 1
    }
}
