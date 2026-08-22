import Foundation

/// Synchronous, process-local snapshot used by non-UI LLM call sites. The
/// email is part of the value so a refresh from account B can never reuse
/// account A's last-known capabilities. This is deliberately not persisted:
/// a fresh launch must confirm the server response before granting BYOK.
enum LlmEntitlementCache {
    private static let lock = NSLock()
    private static var email: String?
    private static var value: LlmEntitlements?

    static func install(_ entitlements: LlmEntitlements?, email: String) {
        lock.lock()
        defer { lock.unlock() }
        self.email = normalized(email)
        value = entitlements
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        email = nil
        value = nil
    }

    static func current(for email: String?) -> LlmEntitlements? {
        lock.lock()
        defer { lock.unlock() }
        guard let email, normalized(email) == self.email else { return nil }
        return value
    }

    private static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum LlmMode: Equatable {
    case managedRelay
    case byok
}

enum LlmEntitlementError: Error, Equatable, LocalizedError {
    case byokNotEntitled
    case managedRelayNotEntitled

    var errorDescription: String? {
        switch self {
        case .byokNotEntitled:
            return "当前账号没有使用自己的 API Key 的权限。"
        case .managedRelayNotEntitled:
            return "当前账号没有使用 whatSub 托管 AI 的权限。"
        }
    }
}

extension LlmEntitlements {
    static let free = LlmEntitlements(
        tier: .free, managedRelay: true, byok: false, tokenTopups: false
    )
    static let buyout = LlmEntitlements(
        tier: .buyout, managedRelay: false, byok: true, tokenTopups: false
    )
    static let pro = LlmEntitlements(
        tier: .pro, managedRelay: true, byok: false, tokenTopups: true
    )
    static let buyoutPro = LlmEntitlements(
        tier: .buyoutPro, managedRelay: true, byok: true, tokenTopups: true
    )
}

enum LlmEntitlementPolicy {
    /// Old servers omit `llmEntitlements`; treat that as the free capability
    /// set. This preserves the existing managed trial path while never
    /// granting a newly introduced BYOK entitlement.
    static func allowedModes(for entitlements: LlmEntitlements?) -> [LlmMode] {
        guard let entitlements else { return [.managedRelay] }
        var modes: [LlmMode] = []
        if entitlements.managedRelay { modes.append(.managedRelay) }
        if entitlements.byok { modes.append(.byok) }
        return modes
    }

    static func effectiveSettings(
        _ stored: LlmSettings,
        entitlements: LlmEntitlements?
    ) -> LlmSettings {
        var result = stored
        let modes = allowedModes(for: entitlements)
        if modes.count == 1, let only = modes.first {
            result.useManagedRelay = (only == .managedRelay)
        } else if modes.isEmpty {
            // Keep the stored secret untouched, but make calls fail through
            // policy instead of accidentally selecting a mode.
            result.useManagedRelay = true
        }
        return result
    }

    static func validateCall(
        settings: LlmSettings,
        entitlements: LlmEntitlements?
    ) throws {
        let requested: LlmMode = settings.useManagedRelay ? .managedRelay : .byok
        guard allowedModes(for: entitlements).contains(requested) else {
            throw requested == .byok
                ? LlmEntitlementError.byokNotEntitled
                : LlmEntitlementError.managedRelayNotEntitled
        }
    }

    static func validateCall(settings: LlmSettings) throws {
        try validateCall(
            settings: settings,
            entitlements: LlmEntitlementCache.current(for: KeychainStore.load()?.email)
        )
    }
}
