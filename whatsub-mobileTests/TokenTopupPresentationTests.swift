import XCTest
@testable import whatsub_mobile

final class TokenTopupPresentationTests: XCTestCase {
    func testPacksAppearOnlyForProEntitlements() {
        XCTAssertFalse(TokenTopupPresentation(entitlements: .free, wallet: nil).isAvailable)
        XCTAssertEqual(
            TokenTopupPresentation(entitlements: .pro, wallet: nil).packTokens,
            [1_000_000, 5_000_000, 15_000_000]
        )
        XCTAssertTrue(TokenTopupPresentation(entitlements: .buyoutPro, wallet: nil).isAvailable)
    }

    func testFrozenWalletIsPresentedAsFrozen() {
        let wallet = TokenWallet(
            monthlyUsed: 5_000_000,
            monthlyLimit: 5_000_000,
            topupBalance: 1_000_000,
            topupFrozen: true,
            periodResetAt: 0
        )
        XCTAssertTrue(TokenTopupPresentation(entitlements: .pro, wallet: wallet).isFrozen)
    }
}
