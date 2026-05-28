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
    @State private var selectedTab: Int = 0
    @State private var pendingImport: IdentifiedImportURL?
    @State private var gateReady = false

    // 2026-05-28 policy shift: dropped the hard paywall after the 1-day trial.
    // The app is fully usable post-install — free tier covers basic Library
    // sync (3 videos / 100MB / 20min) + personal corpus (50 entries). Pro-only
    // capabilities (公共语料库, expanded quotas) are now gated CONTEXTUALLY by
    // the surfaces that need them (CorpusView's 公共 tab, ImportView quotaWall),
    // which present SubscribeSheet on tap. No more 2-tier ¥18 buyout + ¥12/月 —
    // single Pro subscription path.

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
        .task(id: appState.isAuthenticated) {
            guard appState.isAuthenticated else { gateReady = false; return }
            store.reportVerifiedJWS = { jws in
                guard let token = appState.session?.sessionToken else { return }
                try? await WhatsubAPI.shared.verifyPurchase(token: token, signedTransactionInfo: jws)
                await appState.refreshMe()
            }
            store.start()
            await appState.refreshMe()
            gateReady = true
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
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "play.rectangle") }
                .tag(0)

            CorpusView()
                .tabItem { Label("语料库", systemImage: "books.vertical") }
                .tag(1)

            MeView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(2)
        }
        .onOpenURL { url in
            guard url.host == "import",
                  let pending = AppGroup.pendingImportURL() else { return }
            AppGroup.clearPendingImportURL()
            pendingImport = IdentifiedImportURL(url: pending)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, pendingImport == nil,
               let saved = AppGroup.pendingImportURL() {
                AppGroup.clearPendingImportURL()
                pendingImport = IdentifiedImportURL(url: saved)
            }
        }
        .sheet(item: $pendingImport) { item in
            NavigationStack {
                ImportView(initialURL: item.url)
                    .environmentObject(appState)
                    .environmentObject(store)
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(AppState()).environmentObject(StoreManager())
}
