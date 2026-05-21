import Foundation
import Combine

/// Root state for the whatSub iOS app.
///
/// Phase 1: empty stub. Phase 2 will hold session, current user, and
/// child view models. Lives at the root via `@StateObject` in
/// `WhatsubMobileApp` and is injected into views via `.environmentObject`.
final class AppState: ObservableObject {
    // Placeholder — Phase 2 will add session + auth gate + tabs.
}
