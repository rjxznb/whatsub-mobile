import SwiftUI
import UIKit

/// Wrapper that gives a pending import URL a stable Identifiable identity so
/// `.sheet(item:)` can drive presentation without repeated triggers.
struct IdentifiedImportURL: Identifiable {
    let id = UUID()
    let url: String
}

@main
struct WhatsubMobileApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var store = StoreManager()

    init() {
        // Force pure-black bars (TabBar + NavigationBar) to match the brand
        // 黑 base. SwiftUI's `.preferredColorScheme(.dark)` alone leaves
        // UIKit-backed bars at #1c1c1e (system dark) instead of #000000.
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = .black
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .black
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(store)
                .tint(.whatsubAccent)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager
    @Environment(\.scenePhase) private var scenePhase
    // `selectedTab` lives on AppState now so the URL handler can drive
    // tab switches from `whatsub://library` / `whatsub://import-queue`
    // taps on the Live Activity (2026-06-18 plan).
    @State private var pendingImport: IdentifiedImportURL?
    @State private var gateReady = false
    /// Global AI-feature consent presentation flag (App Store Guideline
    /// 5.1.1(i) / 5.1.2(i), 2026-06-09). Bound via the AIConsentStore
    /// singleton: presented exactly once per install, before any AI call
    /// can succeed. See `AIConsentGate.swift` for the disclosure body.
    @State private var showAIConsent = false
    @ObservedObject private var consentStore = AIConsentStore.shared

    /// One-time VPN split-routing onboarding (2026-07-20). Presented once,
    /// only when a VPN tunnel is detected at launch — the single biggest
    /// acquisition blocker for CN users was "反复开关 VPN", and the durable
    /// fix (rule-mode + one DIRECT rule) lives in VPNRuleHelpSheet.
    @AppStorage("vpn.onboarding.shown") private var vpnOnboardingShown = false
    @State private var showVPNOnboarding = false

    // 2026-05-28 policy shift: dropped the hard paywall after the 1-day trial.
    // The app is fully usable post-install — free tier covers basic Library
    // sync (3 videos / 100MB / 20min) + personal corpus (50 entries). Pro-only
    // capabilities (公共语料库, expanded quotas) are now gated CONTEXTUALLY by
    // the surfaces that need them (CorpusView's 公共 tab, ImportView quotaWall),
    // which present SubscribeSheet on tap. No more 2-tier ¥18 buyout + ¥12/月 —
    // single Pro subscription path (¥22/月 + ¥168/年 since 2026-06-04;
    // includes managed-LLM relay — users no longer need their own DeepSeek key).

    var body: some View {
        Group {
            if appState.isAuthenticated {
                if !gateReady {
                    splash
                } else {
                    mainTabs
                }
            } else {
                AuthGateView()
            }
        }
        // (2026-06-03) Don't BLOCK app entry on a network refresh — without
        // internet, the URLSession.data(for:) call inside refreshMe() hangs
        // for ~60 s until it times out, and the splash stays up the entire
        // time. The standard pattern for offline-aware apps: have a session
        // → enter UI immediately, refresh in the background, fall back to
        // cached `currentUser` if the network call fails. App Review tests
        // offline launch behavior + would flag the 60s freeze as a 4.0
        // ("Apps may not freeze on launch") rejection.
        .task(id: appState.isAuthenticated) {
            guard appState.isAuthenticated else { gateReady = false; return }
            // 2026-06-11 — was `try? await ...` which silently swallowed every
            // backend /verify failure. Apple's reviewer purchased successfully
            // via StoreKit but the call to /api/license/iap/verify failed
            // (likely a transient network blip OR OCSP-from-Beijing flakiness)
            // and the user saw "未订阅" with no error. Apple flagged it as
            // Guideline 2.1(b) "purchased product not credited".
            //
            // Now we retry up to 3 times with exponential backoff, surface
            // any final failure into StoreManager.lastError (which MeView
            // already renders), and ALWAYS call refreshMe afterward so
            // /me sees the new entitlement.
            store.reportVerifiedJWS = { jws in
                guard let token = appState.session?.sessionToken else { return }
                let backoffs: [UInt64] = [0, 500_000_000, 2_000_000_000]
                var lastErr: Error?
                for delay in backoffs {
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    do {
                        try await WhatsubAPI.shared.verifyPurchase(
                            token: token, signedTransactionInfo: jws,
                        )
                        lastErr = nil
                        break
                    } catch {
                        lastErr = error
                    }
                }
                if let err = lastErr {
                    await MainActor.run {
                        let msg = (err as? LocalizedError)?.errorDescription
                            ?? err.localizedDescription
                        store.lastError =
                            "购买已扣款,但向服务器登记会员状态失败,请稍后到「我的」下拉刷新,或联系客服。(\(msg))"
                    }
                }
                await appState.refreshMe()
            }
            store.start()
            // Enter UI right away. The detached Task refreshes /me in the
            // background — UI shows mainTabs with the cached `currentUser`
            // (last known entitlements) while it runs, and the @Published
            // currentUser update from a successful refresh trickles into
            // dependent views on its own.
            gateReady = true
            Task { await appState.refreshMe() }
        }
        // AI consent — presented at the OUTER body level (not inside
        // mainTabs) so the sheet modifier is mounted on a view that's
        // always present, regardless of gateReady / isAuthenticated. The
        // earlier version (build 294) hooked .onChange(of: gateReady)
        // INSIDE mainTabs, but mainTabs only renders when gateReady is
        // already true — so the false→true transition happened before
        // the listener was bound, and the sheet never showed.
        //
        // The .task below runs on every cold launch (no id, so it fires
        // once per view lifetime) and right after `gateReady` flips on.
        // The condition is "has the user accepted yet?" — if not, show
        // the sheet. Once they tap "同意并继续", AIConsentStore.accept()
        // sets the flag, AIConsentGate sets `presenting = false`, sheet
        // dismisses. Apple's Guideline 5.1.1(i) / 5.1.2(i) doesn't say
        // WHEN exactly the consent must show; "before sending data" is
        // the rule, and pre-mainTabs is well before any AI button is
        // tappable.
        .task(id: gateReady) {
            if gateReady && !consentStore.hasAccepted {
                showAIConsent = true
            }
        }
        .sheet(isPresented: $showAIConsent) {
            AIConsentGate(presenting: $showAIConsent)
        }
        // One-time VPN split-routing onboarding (2026-07-20). TARGETED: only
        // fires when a VPN tunnel is actually detected — non-VPN users never
        // see it. Deferred behind the AI-consent sheet (two stacked sheets on
        // first launch would fight); since the shown-flag is only set when we
        // actually present, a launch that skipped it re-attempts next launch.
        // Mounted at the outer body level for the same reason as AI consent
        // (see comment above).
        .task(id: gateReady) {
            if gateReady && consentStore.hasAccepted
                && !vpnOnboardingShown && VPNDetector.isVPNActive() {
                vpnOnboardingShown = true
                showVPNOnboarding = true
            }
        }
        .sheet(isPresented: $showVPNOnboarding) {
            VPNRuleHelpSheet()
        }
    }

    private var splash: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            (Text("what").foregroundColor(.white) + Text("Sub").foregroundColor(.whatsubAccent))
                .font(.custom("Caveat-Bold", size: 64))
        }
    }

    private var mainTabs: some View {
        TabView(selection: $appState.selectedTab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "play.rectangle") }
                .tag(0)

            CorpusView()
                .tabItem { Label("语料库", systemImage: "books.vertical") }
                .tag(1)

            // 「实景口语」 (renamed from 眼前, 2026-06-05) — primary
            // surface is the LiveScene flow (picker → Vision → LLM →
            // speak → grade) inline; 拍照翻译 sits in the header's
            // top-right toolbar. Custom CameraTabIcon SVG asset stays.
            // Tab label is 4 chars (vs the full 实景口语练习 6 chars)
            // so it fits comfortably alongside the other tab labels
            // on smaller iPhones without truncation.
            CameraTabView()
                .tabItem { Label("实景口语", image: "CameraTabIcon") }
                .tag(2)

            MeView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(3)
        }
        .onOpenURL { url in
            // Share Extension import handoff (whatsub://import?url=…) —
            // existing path, leave behavior identical.
            if url.host == "import" {
                if let pending = AppGroup.pendingImportURL() {
                    AppGroup.clearPendingImportURL()
                    pendingImport = IdentifiedImportURL(url: pending)
                }
                return
            }
            // Live Activity tap destinations (2026-06-18 plan, Phase 5.4).
            // Both routes are idempotent: if already at the destination,
            // setting the bindings to the same value is a no-op.
            switch url.host {
            case "library":
                appState.selectedTab = 0
            case "import-queue":
                appState.selectedTab = 3
                appState.meShowImportQueue = true
            default:
                break
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if pendingImport == nil,
                   let saved = AppGroup.pendingImportURL() {
                    AppGroup.clearPendingImportURL()
                    pendingImport = IdentifiedImportURL(url: saved)
                }
                // Drive the LiveActivity cooldown latch on foreground —
                // tears the Activity down 10 min after the last work item
                // drained. Cheap when no Activity exists (early-return).
                // iOS 16.2+ guard: ActivityKit is unavailable on 16.0.
                if #available(iOS 16.2, *) {
                    Task { await LiveActivityCoordinator.shared.endIfStale() }
                }
            }
        }
        .sheet(item: $pendingImport) { item in
            NavigationStack {
                ImportView(initialURL: item.url)
                    .environmentObject(appState)
                    .environmentObject(store)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { pendingImport = nil }
                        }
                    }
            }
            // Disable swipe-down dismiss so users don't accidentally close
            // mid-extract / mid-AI / mid-preview. Explicit "关闭" button
            // gives them a deliberate exit. Mirrors the LibraryView import
            // sheet's interactive-dismiss policy.
            .interactiveDismissDisabled()
        }
        // (AI consent sheet moved to the OUTER body — see comment there
        // for the build-294 bug rationale. Don't add it here again or the
        // false→true transition gets missed during the mainTabs mount.)
    }
}

#Preview {
    ContentView().environmentObject(AppState()).environmentObject(StoreManager())
}
