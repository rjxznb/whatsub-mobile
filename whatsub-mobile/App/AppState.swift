import Foundation
import SwiftUI

/// Root state. Holds the session + current user. On launch, tries to restore
/// a valid session from Keychain. Exposes a published `isAuthenticated` the
/// root scene reads to decide whether to show the AuthGate.
@MainActor
final class AppState: ObservableObject {
    @Published var session: Session?
    @Published var currentUser: MeResponse?

    /// Bottom-tab selection. Lifted out of ContentView's local @State so
    /// deep-link handlers (whatsub://library, whatsub://import-queue) can
    /// drive tab switches when an Activity is tapped. Tab indices match
    /// ContentView.mainTabs order: 0 Library / 1 语料库 / 2 实景口语 / 3 我的.
    @Published var selectedTab: Int = 0

    /// Set by the whatsub://import-queue deep link to push ImportQueueView
    /// onto the 我的 tab's NavigationStack. MeView binds this to a
    /// `NavigationLink(isActive:)` (iOS 16 compatible) and the system flips
    /// it back to false on pop. Same binding also drives the visible
    /// 导入队列 row tap, so the destination has a single source of truth.
    /// Idempotent — re-tapping while already at the destination just
    /// re-sets the binding to true (no-op for a destination already on the
    /// stack).
    @Published var meShowImportQueue: Bool = false

    var isAuthenticated: Bool { session?.isValid == true }

    init() {
        // Restore a non-expired session synchronously at launch.
        if let saved = KeychainStore.load(), saved.isValid {
            session = saved
        } else if KeychainStore.load() != nil {
            KeychainStore.clear() // expired — drop it
        }
    }

    func setSession(_ s: Session) {
        try? KeychainStore.save(s)
        session = s
    }

    func logout() {
        if let token = session?.sessionToken {
            Task { await WhatsubAPI.shared.logout(token: token) }
        }
        KeychainStore.clear()
        session = nil
        currentUser = nil
    }

    /// Called after login + on app foreground to refresh license status.
    func refreshMe() async {
        guard let token = session?.sessionToken else { return }
        do {
            currentUser = try await WhatsubAPI.shared.me(token: token)
        } catch APIError.unauthorized {
            // Session died server-side — force re-login.
            forceLogout()
        } catch {
            // Non-fatal: keep last-known currentUser, UI shows stale-but-usable.
        }
    }

    func forceLogout() {
        KeychainStore.clear()
        session = nil
        currentUser = nil
    }
}
