import Foundation
import SwiftUI

/// State machine for the 角色扮演 tab inside `LibraryDetailView`. Loads
/// scenarios on first appear, keeps them cached for the lifetime of the
/// view, and exposes `picked` for the parent to drive a session sheet.
@MainActor
final class RoleplayTabViewModel: ObservableObject {

    @Published private(set) var phase: RoleplayPhase = .idle
    @Published private(set) var scenarios: [RoleplayScenario] = []
    /// Set when the user picks a scenario card. Parent observes this to
    /// present `RoleplaySessionView` as a sheet. Cleared when the sheet
    /// dismisses (via `dismissSession()`).
    @Published var picked: RoleplayScenario?
    /// Epoch seconds of the last cache write for this entry. Drives the
    /// "上次生成 · X 前" hint above the regenerate button.
    @Published private(set) var lastGeneratedAt: Double?

    private let entry: LibraryEntryDetail
    /// Mutable so the view can hand corpus phrases in AFTER init (the
    /// fetch is async and only finishes after `task(id:)` runs). Setting
    /// these before `load()` is what makes scene derivation use them.
    private var corpusPhrases: [String]
    private let client: RoleplayScenarioClient
    private let cache: RoleplayScenarioCache

    init(entry: LibraryEntryDetail,
         corpusPhrases: [String],
         settings: LlmSettings = LlmSettingsStore.load(),
         cache: RoleplayScenarioCache = RoleplayScenarioCache()) {
        self.entry = entry
        self.corpusPhrases = corpusPhrases
        self.client = .live(settings: settings)
        self.cache = cache
    }

    /// Called by the view once `WhatsubAPI.mineCorpus` resolves. We
    /// store the phrases for any FUTURE regenerate; we do NOT
    /// re-derive automatically on corpus drift — fingerprint logic in
    /// the cache makes this a no-op unless the user explicitly hits
    /// 「重新生成」.
    func _setCorpusPhrasesAndReloadIfIdle(_ phrases: [String]) async {
        corpusPhrases = phrases
        // 2026-06-04: removed the auto-reload-on-late-corpus-arrival
        // branch. Even if the picker is showing scenes derived from
        // an empty corpus, we honor them until the user explicitly
        // regenerates — that's what cache persistence implies.
    }

    /// Idempotent. On first entry to the tab tries the on-disk cache;
    /// if it has scenes for this entry → render immediately (zero LLM
    /// call). Otherwise call the LLM and persist. Use `regenerate()`
    /// for the "重新生成" button to force a fresh LLM call.
    func loadIfNeeded() async {
        guard case .idle = phase else { return }
        if let cached = cache.get(entryId: entry.id), !cached.scenarios.isEmpty {
            scenarios = cached.scenarios
            lastGeneratedAt = cached.savedAt
            phase = .picker
            return
        }
        await derive(persistOnSuccess: true)
    }

    /// User-triggered fresh LLM call. Overwrites the cache row on
    /// success; on failure we keep the existing cached set (so the tab
    /// still has something to render) and just surface the error.
    func regenerate() async {
        await derive(persistOnSuccess: true)
    }

    func pick(_ scenario: RoleplayScenario) {
        picked = scenario
        phase = .inSession
    }

    /// Called by the parent when the session sheet dismisses.
    func dismissSession() {
        picked = nil
        // Stay on the picker so the user can replay or pick a new scenario.
        phase = .picker
    }

    // MARK: - private

    /// One LLM call + state transition. `persistOnSuccess` controls
    /// whether a success path writes the cache (always true at the
    /// moment; left as a hook for future "preview / don't save" flows).
    private func derive(persistOnSuccess: Bool) async {
        phase = .loading

        // Fast-path guard: if the user hasn't configured an LLM key (AND
        // isn't on the managed-relay tier), there's no point making the
        // call — surface a configureLLM-kind error so the UI can deep-link
        // 我的 → LLM 设置 if it wants to.
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            phase = .error(RemoteFailure(
                message: "想生成专属场景需要先配置 AI——打开「我的 → LLM 设置」填好 API Key 再回来。",
                kind: .configureLLM
            ))
            return
        }

        let result = await client.deriveScenarios(
            entry: entry,
            corpusPhrases: corpusPhrases
        )

        switch result {
        case .success(let list):
            scenarios = list
            if persistOnSuccess {
                cache.put(entryId: entry.id,
                          scenarios: list,
                          corpusPhrases: corpusPhrases)
                lastGeneratedAt = Date().timeIntervalSince1970
            }
            phase = .picker
        case .failure(let f):
            // The fallback scene keeps the tab usable even when the LLM
            // refused. We surface the error message but ALSO inject the
            // stock so the user has something to tap. We do NOT persist
            // a fallback row — next launch tries the LLM again.
            let stock = RoleplayScenarioClient.stockFallback(videoTitle: entry.title)
            // If we have a cached set, keep it instead of clobbering with
            // a single stock card.
            if scenarios.isEmpty {
                scenarios = [stock]
            }
            phase = .error(f)
        }
    }
}
