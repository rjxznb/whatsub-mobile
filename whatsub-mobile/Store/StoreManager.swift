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

    @Published var purchaseInProgress = false
    @Published var lastError: String?
    @Published var subMonth: Product?
    @Published var subYear: Product?
    /// Offline-capable: StoreKit shows a current (non-expired) subscription on this device.
    @Published var hasLocalSub = false

    /// Set by the app: given a verified JWS, report it to the backend + refresh entitlements.
    var reportVerifiedJWS: ((String) async -> Void)?

    private var updatesTask: Task<Void, Never>?

    /// Load products + start the transaction-updates listener. Idempotent.
    func start() {
        Task { await loadProducts() }
        Task { await refreshLocalEntitlements() }
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(update)
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
            let result = try await product.purchase()
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
    /// any current entitlements to the backend.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            // user-cancelled or offline — fall through to whatever StoreKit already has
        }
        for await result in Transaction.currentEntitlements {
            if case .verified = result {
                await reportVerifiedJWS?(result.jwsRepresentation)
            }
        }
        await refreshLocalEntitlements()
    }

    // MARK: - internals

    @discardableResult
    private func process(_ result: VerificationResult<Transaction>) async -> Bool {
        switch result {
        case .verified(let transaction):
            await reportVerifiedJWS?(result.jwsRepresentation)
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
