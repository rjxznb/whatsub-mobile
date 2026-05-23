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
                .tint(.whatsubAccent)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Int = 0
    @State private var pendingImport: IdentifiedImportURL?

    var body: some View {
        Group {
            if appState.isAuthenticated {
                TabView(selection: $selectedTab) {
                    LibraryView()
                        .tabItem {
                            Label("Library", systemImage: "play.rectangle")
                        }
                        .tag(0)

                    CorpusView()
                        .tabItem {
                            Label("语料库", systemImage: "books.vertical")
                        }
                        .tag(1)

                    MeView()
                        .tabItem {
                            Label("我的", systemImage: "person.crop.circle")
                        }
                        .tag(2)
                }
                .onOpenURL { url in
                    guard url.host == "import",
                          let pending = AppGroup.pendingImportURL() else { return }
                    AppGroup.clearPendingImportURL()
                    pendingImport = IdentifiedImportURL(url: pending)
                }
                .onChange(of: scenePhase) { phase in
                    // Safety-net: if the responder-chain openURL didn't fire but
                    // the extension already saved the URL, pick it up on foreground.
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
                    }
                }
            } else {
                AuthGateView()
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
