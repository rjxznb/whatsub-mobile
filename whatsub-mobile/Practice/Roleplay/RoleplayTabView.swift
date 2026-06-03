import SwiftUI

/// The 角色扮演 tab inside `LibraryDetailView`. Renders the LLM-derived
/// scene cards; tap a card → presents `RoleplaySessionView` as a sheet.
///
/// Corpus phrases for this video are loaded once on appear via the same
/// API call `EntryCollectionsList` uses. We don't share a fetcher between
/// the two because the tabs are usually mutually exclusive (the user is
/// in one or the other at a time), and each does its own task(id:) so
/// switching tabs doesn't force a reload of the other.
struct RoleplayTabView: View {
    let entry: LibraryEntryDetail

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm: RoleplayTabViewModel
    @State private var loadedCorpusPhrases: [String] = []
    @State private var corpusLoaded = false

    init(entry: LibraryEntryDetail) {
        self.entry = entry
        _vm = StateObject(wrappedValue: RoleplayTabViewModel(
            entry: entry, corpusPhrases: []
        ))
    }

    var body: some View {
        Group {
            switch vm.phase {
            case .idle, .loading:
                loadingView
            case .picker:
                pickerList
            case .inSession:
                // The session sheet is presented via the .sheet modifier;
                // leave the picker visible underneath so dismiss returns to
                // a familiar surface.
                pickerList
            case .error(let msg):
                // Even on error we render the fallback scenario card so
                // the user can still play with something. The error banner
                // shows above.
                VStack(spacing: 12) {
                    errorBanner(msg)
                    pickerList
                }
            }
        }
        .task(id: entry.id) {
            await loadCorpusPhrasesIfNeeded()
            await vm.loadIfNeeded()
        }
        .sheet(item: $vm.picked) { scenario in
            RoleplaySessionView(scenario: scenario)
                .onDisappear { vm.dismissSession() }
        }
    }

    // MARK: - subviews

    private var loadingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().tint(.whatsubAccent)
            Text("正在为这个视频量身设计场景…")
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pickerList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(vm.scenarios) { s in
                    RoleplayScenarioCard(scenario: s) {
                        vm.pick(s)
                    }
                }

                Button {
                    Task { await vm.reload() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("换一组场景")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(.whatsubInkMuted)
                    .background(Color.whatsubBgElev.opacity(0.5),
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .disabled(vm.phase == .loading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.whatsubInkMuted)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    // MARK: - data loading

    /// Pull the user's corpus phrases tagged to this video so the scene-
    /// derivation prompt can anchor scenes to them. Best-effort — failure
    /// just means we generate scenes off subtitles alone.
    private func loadCorpusPhrasesIfNeeded() async {
        guard !corpusLoaded else { return }
        corpusLoaded = true
        guard let token = appState.session?.sessionToken else { return }
        do {
            let resp = try await WhatsubAPI.shared.mineCorpus(tags: [], token: token)
            loadedCorpusPhrases = resp.items
                .filter { $0.source.libraryEntryId == entry.id }
                .map { $0.phraseRaw }
            // VM needs the fresh phrases for its first load; rebuild it.
            // (StateObject doesn't replace on its own; we update the
            // internal store via a new instance.)
            // Cheapest path: nudge the VM to reload IF it's still idle.
            // Implementation: since the VM was init'd with [] phrases,
            // we'd need a setter. Simplest: just kick a reload — the
            // LLM will re-derive with the new corpus list since the
            // VM reads from its init params. To avoid threading a setter
            // through, expose `setCorpusPhrasesAndReload`.
            await vm.setCorpusPhrasesAndReloadIfIdle(loadedCorpusPhrases)
        } catch {
            // Silent — scene derivation still works without corpus context.
        }
    }
}

/// Convenience setter — the tab's corpus-phrase fetch happens AFTER the VM
/// was init'd (because corpus is an async API call), and we want the
/// derivation prompt to include them. This lets the View hand them back in
/// without a re-init.
extension RoleplayTabViewModel {
    func setCorpusPhrasesAndReloadIfIdle(_ phrases: [String]) async {
        // Replace the underlying client / state. Cheapest implementation:
        // construct a fresh client and call load() with the new phrases
        // baked into a re-derived prompt. The struct is value-type so we
        // just rebuild it.
        await self._setCorpusPhrasesAndReloadIfIdle(phrases)
    }
}
