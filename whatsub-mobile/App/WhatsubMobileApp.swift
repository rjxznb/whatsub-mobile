import SwiftUI
import UIKit

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
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            CorpusPlaceholderView()
                .tabItem {
                    Label("语料库", systemImage: "books.vertical")
                }
                .tag(0)

            LibraryPlaceholderView()
                .tabItem {
                    Label("Library", systemImage: "play.rectangle")
                }
                .tag(1)

            MePlaceholderView()
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
                .tag(2)
        }
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
