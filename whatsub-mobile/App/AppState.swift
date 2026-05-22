import Foundation
import SwiftUI

/// Root state. Holds the session + current user. On launch, tries to restore
/// a valid session from Keychain. Exposes a published `isAuthenticated` the
/// root scene reads to decide whether to show the AuthGate.
@MainActor
final class AppState: ObservableObject {
    @Published var session: Session?
    @Published var currentUser: MeResponse?

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
