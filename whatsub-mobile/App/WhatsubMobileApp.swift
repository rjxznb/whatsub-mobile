import SwiftUI

@main
struct WhatsubMobileApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .tint(.whatsubAccent)
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
