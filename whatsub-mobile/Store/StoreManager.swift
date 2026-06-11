import Foundation
import StoreKit

/// StoreKit 2 wrapper for whatSub Pro subscriptions (¥22/月, ¥168/年, bumped
/// from ¥12/¥88 on 2026-06-04 to fund the managed-LLM relay — spec at
/// `Get_Video/docs/superpowers/specs/2026-06-03-whatsub-managed-llm-relay.md`).
/// All UI shows `product.displayPrice` (StoreKit-driven, picks up ASC tier
/// changes automatically), so this comment is the only iOS-side place that
/// hardcodes the headline numbers.
///
/// Loads the products, runs purchases, listens for transaction updates,
/// exposes an offline-capable local entitlement check, and reports verified
/// signed transactions to the backend via `reportVerifiedJWS` (set by the
/// app — does /iap/verify + refreshMe).
///
/// 2026-05-28 cleanup: the legacy ¥18 buyout SKU (`cc.eversay.whatsub.mobile.
/// fullunlock`) was fully deleted in App Store Connect — never reached real
/// purchases, no grandfathering needed. All buyout-related code paths removed.
@MainActor
final class StoreManager: ObservableObject {
    static let subMonthID = "whatsub_pro_month"
    static let subYearID  = "whatsub_pro_year"

    /// Fixed random namespace UUID for derived `appAccountToken`s. Pinned
    /// so the same email always yields the same UUID across reinstalls,
    /// across our backend + iOS code, across the lifetime of the product.
    /// Generated once, NEVER rotated — rotating would orphan every existing
    /// subscription from server-side reverse-resolution.
    /// 2026-06-11 (Guideline 2.1(b) follow-up).
    static let whatsubIAPNamespace = UUID(uuidString: "8A1D4B3F-2E6C-4A9B-B7E5-9D3F8C1E2A6B")!

    @Published var purchaseInProgress = false
    @Published var lastError: String?
    @Published var subMonth: Product?
    @Published var subYear: Product?
    /// Offline-capable: StoreKit shows a current (non-expired) subscription on this device.
    @Published var hasLocalSub = false

    /// Set by the app: given a verified JWS, report it to the backend + refresh entitlements.
    var reportVerifiedJWS: ((String) async -> Void)?

    private var updatesTask: Task<Void, Never>?

    /// Load products + start the transaction-updates listener + RE-REPORT
    /// any existing iOS entitlements to the backend. Idempotent.
    ///
    /// The re-report step was added 2026-06-07 to fix "我的 page shows 未订阅
    /// after app update". `Transaction.updates` only fires for NEW
    /// transactions — an existing subscription that survived an app update
    /// would never emit through that channel, so the backend (which is the
    /// source of truth `MeView` reads via `/me.hasActiveSubscription`) never
    /// learned that the device still had the entitlement on this build.
    /// Iterating `Transaction.currentEntitlements` once on every cold start
    /// and POSTing each verified JWS to `/iap/verify` keeps the backend in
    /// sync without requiring user interaction (StoreKit's `AppStore.sync()`
    /// requires a tap and is reserved for `restore()`). `/iap/verify` is
    /// idempotent server-side, so re-reporting on every launch is cheap and
    /// correct.
    func start() {
        Task { await loadProducts() }
        Task { await refreshLocalEntitlements() }
        Task { await reportCurrentEntitlements() }
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(update)
            }
        }
    }

    /// Re-report any verified subscription/buyout entitlement on this
    /// device to the backend. Safe to call repeatedly — `/iap/verify` is
    /// idempotent and the backend de-dupes by transaction id.
    ///
    /// Called automatically by `start()` (cold-launch path) and exposed
    /// publicly so `MeView`'s pull-to-refresh can also force it without
    /// going through StoreKit's UI-blocking `AppStore.sync()`.
    func reportCurrentEntitlements() async {
        guard let report = reportVerifiedJWS else { return }
        for await result in Transaction.currentEntitlements {
            if case .verified = result {
                await report(result.jwsRepresentation)
            }
        }
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.subMonthID, Self.subYearID])
            for p in products {
                switch p.id {
                case Self.subMonthID: subMonth = p
                case Self.subYearID:  subYear = p
                default: break
                }
            }
        } catch {
            lastError = "无法加载商品，请检查网络后重试"
        }
    }

    /// Buy a subscription (month or year). Verify → report JWS → refresh entitlements.
    func purchaseSubscription(_ product: Product) async -> Bool { await purchase(product) }

    private func purchase(_ product: Product?) async -> Bool {
        guard let product else {
            lastError = "商品未就绪，请稍后重试"
            return false
        }
        lastError = nil
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            // 2026-06-11 — derive appAccountToken from session email
            // (UUIDv5 with whatsubIAPNamespace) so that:
            //   1. Every JWS our /verify endpoint sees carries the token
            //      and stores it in iap_account_tokens.
            //   2. Every later ASSN webhook (DID_RENEW / EXPIRED / REFUND)
            //      carries the same token, letting the backend reverse-
            //      resolve the owner email even if /verify never reached
            //      us (network outage, OCSP failure, etc.).
            // When not signed in (user paying without a session — shouldn't
            // happen but UI doesn't enforce), fall back to a random UUID:
            // Apple still accepts the purchase, just no reverse-resolution.
            let email = KeychainStore.load()?.email ?? ""
            let appAccountUUID: UUID = email.isEmpty
                ? UUID()
                : UUID.v5(name: email.trimmingCharacters(in: .whitespaces).lowercased(),
                          namespace: Self.whatsubIAPNamespace)

            let result = try await product.purchase(options: [.appAccountToken(appAccountUUID)])
            switch result {
            case .success(let verification):
                return await process(verification)
            case .userCancelled:
                return false
            case .pending:
                lastError = "购买待确认"
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "购买失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Restore prior purchases (换机/重装). Forces a StoreKit sync, then re-reports
    /// any current entitlements to the backend. Same fire-and-forget treatment
    /// as `process()` — UI doesn't wait on the backend roundtrip; local
    /// StoreKit entitlements drive hasLocalSub immediately.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            // user-cancelled or offline — fall through to whatever StoreKit already has
        }
        if let report = reportVerifiedJWS {
            for await result in Transaction.currentEntitlements {
                if case .verified = result {
                    let jws = result.jwsRepresentation
                    Task { await report(jws) }
                }
            }
        }
        await refreshLocalEntitlements()
    }

    // MARK: - internals

    @discardableResult
    private func process(_ result: VerificationResult<Transaction>) async -> Bool {
        switch result {
        case .verified(let transaction):
            // 2026-06-11 — reportVerifiedJWS now fires-and-forgets in a
            // detached Task so the UI doesn't hang while the backend
            // /verify roundtrip (potentially 3 retries × backoff = ~5 s)
            // completes. Local StoreKit entitlements update IMMEDIATELY
            // via refreshLocalEntitlements() below, so hasLocalSub
            // becomes true the moment Apple confirmed — MeView reads
            // hasLocalSub as a Pro signal even before /me catches up.
            // Apple Guideline 2.1(b) fix.
            if let report = reportVerifiedJWS {
                let jws = result.jwsRepresentation
                Task { await report(jws) }
            }
            await transaction.finish()
            await refreshLocalEntitlements()
            return true
        case .unverified:
            lastError = "交易校验未通过"
            return false
        }
    }

    private func refreshLocalEntitlements() async {
        var sub = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result {
                if t.productID == Self.subMonthID || t.productID == Self.subYearID { sub = true }
            }
        }
        hasLocalSub = sub
    }
}
