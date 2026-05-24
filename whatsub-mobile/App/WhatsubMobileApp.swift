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

    /// Whether to show the paywall. Fails OPEN when we don't have a definitive
    /// answer (currentUser nil — offline / pre-deploy) or when StoreKit shows a
    /// local buyout, so we never wrongly lock out a paying or offline user.
    private var locked: Bool {
        guard let user = appState.currentUser else { return false }
        if store.hasLocalBuyout { return false }
        return !user.appUnlocked
    }

    var body: some View {
        Group {
            if appState.isAuthenticated {
                if !gateReady {
                    splash
                } else if locked {
                    PaywallView()
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
