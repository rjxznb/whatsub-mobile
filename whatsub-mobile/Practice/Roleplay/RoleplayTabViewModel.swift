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

    private let entry: LibraryEntryDetail
    /// Mutable so the view can hand corpus phrases in AFTER init (the
    /// fetch is async and only finishes after `task(id:)` runs). Setting
    /// these before `load()` is what makes scene derivation use them.
    private var corpusPhrases: [String]
    private let client: RoleplayScenarioClient

    init(entry: LibraryEntryDetail,
         corpusPhrases: [String],
         settings: LlmSettings = LlmSettingsStore.load()) {
        self.entry = entry
        self.corpusPhrases = corpusPhrases
        self.client = .live(settings: settings)
    }

    /// Called by the view once `WhatsubAPI.mineCorpus` resolves. If the
    /// initial `loadIfNeeded()` hasn't run yet, the phrases will land in
    /// the prompt naturally on the first `load()`; if the load already
    /// finished without them, we kick a re-derive so the user sees scenes
    /// anchored to their actual corpus.
    func _setCorpusPhrasesAndReloadIfIdle(_ phrases: [String]) async {
        let previouslyEmpty = corpusPhrases.isEmpty
        corpusPhrases = phrases
        // Only reload if (a) we had no phrases the first time AND
        // (b) we're now in picker state (initial load already finished
        // without corpus context). idle/loading states will pick the
        // phrases up via the natural load().
        if previouslyEmpty, !phrases.isEmpty, case .picker = phase {
            await load()
        }
    }

    /// Idempotent — re-entering the tab won't re-fire the LLM call. Use
    /// `reload()` for the "换一组场景" button.
    func loadIfNeeded() async {
        guard case .idle = phase else { return }
        await load()
    }

    /// Force a fresh LLM call (used by "换一组场景" button).
    func reload() async {
        await load()
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

    private func load() async {
        phase = .loading

        // Fast-path guard: if the user hasn't configured an LLM key, there's
        // no point making the call — surface the same error the orb would.
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            phase = .error("先到「我的 → LLM 设置」填好 API Key，再回来生成场景")
            return
        }

        let result = await client.deriveScenarios(
            entry: entry,
            corpusPhrases: corpusPhrases
        )

        switch result {
        case .success(let list):
            scenarios = list
            phase = .picker
        case .failure(let msg):
            // The fallback scene keeps the tab usable even when the LLM
            // refused. We surface the error message but ALSO inject the
            // stock so the user has something to tap.
            let stock = RoleplayScenarioClient.stockFallback(videoTitle: entry.title)
            scenarios = [stock]
            phase = .error(msg)
        }
    }
}
