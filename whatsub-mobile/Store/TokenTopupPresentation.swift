import Foundation

struct TokenTopupPresentation: Equatable {
    let isAvailable: Bool
    let packTokens: [Int]
    let isFrozen: Bool

    init(entitlements: LlmEntitlements?, wallet: TokenWallet?) {
        isAvailable = entitlements?.tokenTopups == true
        packTokens = isAvailable ? [1_000_000, 5_000_000, 15_000_000] : []
        isFrozen = wallet?.topupFrozen == true
    }
}
