import SwiftUI

/// The 角色扮演 tab inside `LibraryDetailView`. Renders the LLM-derived
/// scene cards; tap a card → presents `RoleplaySessionView` as a fullscreen
/// cover (iPad-friendly: a regular `.sheet(item:)` would render as a
/// formSheet floating modal — see issue 2026-06-07 user report).
///
/// Corpus phrases for this video are loaded once on appear via the same
/// API call `EntryCollectionsList` uses. We don't share a fetcher between
/// the two because the tabs are usually mutually exclusive (the user is
/// in one or the other at a time), and each does its own task(id:) so
/// switching tabs doesn't force a reload of the other.
struct RoleplayTabView: View {
    let entry: LibraryEntryDetail
    /// Called right when the roleplay session sheet first appears — the
    /// parent (`LibraryDetailView`) uses it to pause the underlying
    /// `AVPlayer` so the video audio doesn't fight the mic/TTS during the
    /// orb dialog. Not auto-resumed on dismiss: the user releases the
    /// session and decides whether to keep watching the video — they tap
    /// play themselves if they want to.
    var onSessionStart: (() -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: StoreManager
    @EnvironmentObject private var featureAccess: FeatureAccessStore
    @StateObject private var vm: RoleplayTabViewModel
    @State private var loadedCorpusPhrases: [String] = []
    @State private var corpusLoaded = false
    /// 订阅 Pro sheet, shown when the LLM relay rejected scene derivation
    /// for tier-related reasons. Attached at view root so phase transitions
    /// don't tear it down.
    @State private var showSubscribe = false
    @State private var featurePaywallOrigin: FeatureKey?
    @State private var sessionGrant: FeatureAccessGrant?
    @State private var accessMessage: String?

    init(entry: LibraryEntryDetail, onSessionStart: (() -> Void)? = nil) {
        self.entry = entry
        self.onSessionStart = onSessionStart
        _vm = StateObject(wrappedValue: RoleplayTabViewModel(
            entry: entry, corpusPhrases: []
        ))
    }

    var body: some View {
        VStack(spacing: 4) {
            FeatureTrialBadge(presentation: featureAccess.presentation(
                for: .videoRoleplay,
                localPro: store.hasLocalSub
            ))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)

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
                case .error(let f):
                    // Even on error we render the fallback scenario card so
                    // the user can still play with something. The error banner
                    // shows above.
                    VStack(spacing: 12) {
                        errorBanner(f)
                        pickerList
                    }
                }
            }
        }
        .task(id: entry.id) {
            await prepareAccessAndLoad()
        }
        // fullScreenCover (NOT sheet) for the session — the orb dialogue
        // is the focal experience, and on iPad a regular sheet renders as
        // a floating formSheet (~700x550pt centered) which feels wrong
        // for the "I'm in a conversation" mental model. Same orientation
        // shift QuickChat got 2026-06-07.
        .fullScreenCover(item: $vm.picked) { scenario in
            if let grant = sessionGrant {
                RoleplaySessionView(
                    scenario: scenario,
                    featureGrant: grant,
                    onFirstValidReply: recordRoleplaySuccess
                )
                .onAppear { onSessionStart?() }
                .onDisappear {
                    vm.dismissSession()
                    sessionGrant = nil
                }
            }
        }
        .sheet(
            isPresented: $showSubscribe,
            onDismiss: { featurePaywallOrigin = nil }
        ) {
            SubscribeSheet(onPurchased: {
                let origin = featurePaywallOrigin
                Task {
                    if let origin, let session = appState.session {
                        featureAccess.sendEvent(
                            .purchaseSuccess,
                            feature: origin,
                            token: session.sessionToken
                        )
                    }
                    await appState.refreshMe()
                    if let session = appState.session {
                        await featureAccess.refresh(
                            token: session.sessionToken,
                            email: session.email,
                            localPro: store.hasLocalSub
                        )
                        await featureAccess.retryPendingConsumes(
                            token: session.sessionToken,
                            email: session.email
                        )
                    }
                    sessionGrant = nil
                    await regenerateWithAccess()
                }
            })
            .environmentObject(store)
        }
        .alert(
            "暂时无法开始",
            isPresented: Binding(
                get: { accessMessage != nil },
                set: { if !$0 { accessMessage = nil } }
            )
        ) {
            Button("重试") { Task { await prepareAccessAndLoad() } }
            Button("取消", role: .cancel) { accessMessage = nil }
        } message: {
            Text(accessMessage ?? "")
        }
    }

    // MARK: - subviews

    private var loadingView: some View {
        // 5s stall → "可能 VPN 拦了" + 查 VPN 规则按钮.
        // 见 Components/RelayLoadingView.swift.
        RelayLoadingView(label: "正在为这个视频量身设计场景…")
    }

    @ViewBuilder
    private var pickerList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(vm.scenarios) { s in
                    RoleplayScenarioCard(scenario: s) {
                        Task { await pickScenario(s) }
                    }
                }

                // 2026-06-04: scenarios are now persisted to
                // Caches/roleplay_scenarios.json, so re-entering the tab
                // does NOT re-burn an LLM call. This button is the only
                // way to force a fresh derivation. The "上次生成 · X 前"
                // hint surfaces when scenes came from the cache so the
                // user knows they're looking at saved content.
                VStack(spacing: 4) {
                    if let savedAt = vm.lastGeneratedAt {
                        Text("上次生成 · \(Self.lastGeneratedLabel(epoch: savedAt))")
                            .font(.caption2)
                            .foregroundStyle(.whatsubInkFaint)
                    }
                    Button {
                        Task { await regenerateWithAccess() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text(vm.phase == .loading ? "重新生成中…" : "重新生成场景")
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(.whatsubInkMuted)
                        .background(Color.whatsubBgElev.opacity(0.5),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.phase == .loading)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Compact banner above the (always-rendered) picker list. When the
    /// failure is `.subscribeUpsell` we add a trailing 「订阅 Pro」 button
    /// so the user can fix the gate without leaving the tab.
    private func errorBanner(_ failure: RemoteFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(.whatsubInkMuted)
                .lineLimit(3)
            Spacer()
            if failure.kind == .subscribeUpsell {
                Button {
                    featurePaywallOrigin = nil
                    showSubscribe = true
                } label: {
                    Text("订阅")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.whatsubAccent, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    // MARK: - feature access

    private func prepareAccessAndLoad() async {
        guard await obtainGrantIfNeeded() else { return }
        await loadCorpusPhrasesIfNeeded()
        await vm.loadIfNeeded()
    }

    private func pickScenario(_ scenario: RoleplayScenario) async {
        guard await obtainGrantIfNeeded() else { return }
        vm.pick(scenario)
    }

    private func regenerateWithAccess() async {
        guard await obtainGrantIfNeeded() else { return }
        await vm.regenerate()
    }

    private func obtainGrantIfNeeded() async -> Bool {
        if sessionGrant?.matches(.videoRoleplay) == true { return true }
        guard let session = appState.session else { return false }
        do {
            sessionGrant = try await featureAccess.start(
                feature: .videoRoleplay,
                token: session.sessionToken,
                email: session.email,
                localPro: store.hasLocalSub
            )
            accessMessage = nil
            return true
        } catch FeatureAccessError.subscriptionRequired {
            featurePaywallOrigin = .videoRoleplay
            featureAccess.sendEvent(
                .paywallShown,
                feature: .videoRoleplay,
                token: session.sessionToken
            )
            showSubscribe = true
        } catch FeatureAccessError.unauthorized {
            appState.forceLogout()
        } catch {
            accessMessage = FeatureAccessError.temporarilyUnavailable.errorDescription
        }
        return false
    }

    private func recordRoleplaySuccess(_ grant: FeatureAccessGrant) {
        guard grant.matches(.videoRoleplay), let session = appState.session else { return }
        featureAccess.recordSuccessfulResult(
            feature: .videoRoleplay,
            grant: grant,
            token: session.sessionToken,
            email: session.email
        )
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

    /// "5 分钟前" / "2 小时前" / "昨天" / "3 天前" / "Mar 12". Stays
    /// short so it sits comfortably above the regenerate button.
    static func lastGeneratedLabel(epoch: Double) -> String {
        let delta = Date().timeIntervalSince1970 - epoch
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86_400 { return "\(Int(delta / 3600)) 小时前" }
        if delta < 86_400 * 7 { return "\(Int(delta / 86_400)) 天前" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日"
        return fmt.string(from: Date(timeIntervalSince1970: epoch))
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
