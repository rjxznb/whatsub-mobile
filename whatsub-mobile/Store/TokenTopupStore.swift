import Foundation
import StoreKit

/// StoreKit 2 consumable flow for Pro Token top-ups.
///
/// A transaction is finished only after the backend has verified and credited
/// its JWS. If verification fails, the transaction remains unfinished and is
/// eligible for redelivery through `Transaction.updates` on the next launch.
@MainActor
final class TokenTopupStore: ObservableObject {
    static let productIDs: Set<String> = [
        "whatsub_token_1m",
        "whatsub_token_5m",
        "whatsub_token_15m",
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var catalog: [TokenTopupProduct] = []
    @Published private(set) var wallet: TokenWallet?
    @Published private(set) var history: [TokenTransaction] = []
    @Published var isLoading = false
    @Published var purchaseInProgress = false
    @Published var lastError: String?

    /// Injectable seams keep the StoreKit orchestration testable without
    /// putting fake prices or token counts into the production settlement
    /// request.
    var loadCatalog: (() async throws -> [TokenTopupProduct])?
    var verifyJWS: ((String) async throws -> VerifyPurchaseResponse)?
    var refreshWallet: (() async throws -> TokenWallet)?
    var loadHistory: (() async throws -> [TokenTransaction])?
    var currentEntitlements: (() -> LlmEntitlements?)?
    var resumePausedJobs: (() async -> Void)?

    private var updatesTask: Task<Void, Never>?

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(update)
            }
        }
        Task { await loadProducts() }
    }

    func reset() {
        wallet = nil
        history = []
        catalog = []
        products = []
        lastError = nil
    }

    func installWallet(_ wallet: TokenWallet?) {
        self.wallet = wallet
    }

    func installHistory(_ history: [TokenTransaction]) {
        self.history = history
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let serverCatalog = try await loadCatalog?() ?? []
            catalog = serverCatalog
            guard !serverCatalog.isEmpty else {
                products = []
                return
            }
            let allowed = Set(serverCatalog.map(\.id)).intersection(Self.productIDs)
            let loaded = try await Product.products(for: allowed)
            // UI is allowed to show only the intersection of server catalog
            // and StoreKit products. StoreKit displayPrice remains the price
            // source; server priceCny is informational/catalog metadata only.
            let catalogIDs = Set(serverCatalog.map(\.id))
            products = loaded.filter { catalogIDs.contains($0.id) }
                .sorted { $0.id < $1.id }
        } catch {
            lastError = "加量包暂时加载失败，请稍后重试。"
            products = []
        }
    }

    func purchase(product: Product) async -> Bool {
        guard catalog.contains(where: { $0.id == product.id }),
              products.contains(where: { $0.id == product.id }) else {
            lastError = "这个加量包暂时不可购买。"
            return false
        }
        guard let entitlements = currentEntitlements?(), entitlements.tokenTopups else {
            lastError = "只有有效 Pro 用户可以购买 Token 加量包。"
            return false
        }
        guard let email = KeychainStore.load()?.email,
              let accountToken = StoreManager.appAccountToken(for: email) else {
            lastError = "请先登录 whatSub 账号。"
            return false
        }

        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
            case .success(let verification):
                return await process(verification)
            case .pending:
                lastError = "购买待确认，确认后会自动到账。"
                return false
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "购买没有完成，请稍后重试。"
            return false
        }
    }

    /// Process one StoreKit verification result. A duplicate backend credit
    /// (`credited == false`) is still a successful, safe-to-finish delivery.
    @discardableResult
    func process(_ result: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let transaction) = result else {
            lastError = "Apple 交易验证失败，暂未扣款到账。"
            return false
        }
        guard Self.productIDs.contains(transaction.productID) else { return false }
        guard let email = KeychainStore.load()?.email,
              let expected = StoreManager.appAccountToken(for: email),
              transaction.appAccountToken == expected else {
            lastError = "这笔交易与当前 whatSub 账号不匹配。"
            return false
        }
        guard let verifyJWS else {
            lastError = "服务器暂时不可用，交易会在恢复网络后自动重试。"
            return false
        }
        do {
            let previousBalance = wallet?.topupBalance
            let response = try await verifyJWS(transaction.jwsRepresentation)
            await transaction.finish()
            if let refreshWallet {
                wallet = try? await refreshWallet()
            } else if let balance = response.topupBalance {
                wallet = wallet.map {
                    TokenWallet(
                        monthlyUsed: $0.monthlyUsed,
                        monthlyLimit: $0.monthlyLimit,
                        topupBalance: balance,
                        topupFrozen: response.topupFrozen ?? $0.topupFrozen,
                        periodResetAt: $0.periodResetAt
                    )
                }
            }
            if let loadHistory {
                history = (try? await loadHistory()) ?? history
            }
            if let newBalance = wallet?.topupBalance,
               previousBalance == nil || newBalance > (previousBalance ?? 0) {
                if let resumePausedJobs {
                    await resumePausedJobs()
                }
            }
            lastError = nil
            return true
        } catch {
            lastError = "购买已由 Apple 确认，但服务器暂时未完成到账；恢复网络后会自动重试。"
            return false
        }
    }
}
