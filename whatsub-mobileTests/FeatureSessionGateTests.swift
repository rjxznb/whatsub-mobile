import XCTest
@testable import whatsub_mobile

final class FeatureSessionGateTests: XCTestCase {
    func testGrantCannotBeReusedAcrossConversationFeatures() {
        let quickChat = FeatureAccessGrant(feature: .quickChat, access: .trial, email: "a@x.com")
        let roleplay = FeatureAccessGrant(feature: .videoRoleplay, access: .trial, email: "a@x.com")

        XCTAssertTrue(quickChat.matches(.quickChat, email: "A@x.com"))
        XCTAssertFalse(quickChat.matches(.videoRoleplay, email: "a@x.com"))
        XCTAssertFalse(quickChat.matches(.quickChat, email: "b@x.com"))
        XCTAssertTrue(roleplay.matches(.videoRoleplay, email: "a@x.com"))
        XCTAssertFalse(roleplay.matches(.quickChat, email: "a@x.com"))
    }

    func testLocalStoreKitSubscriptionIsScopedToItsWhatSubAccount() {
        let aliceToken = StoreManager.appAccountToken(for: "alice@x.com")!

        XCTAssertTrue(StoreManager.ownsLocalSubscription(
            appAccountTokens: [aliceToken],
            email: "ALICE@x.com"
        ))
        XCTAssertFalse(StoreManager.ownsLocalSubscription(
            appAccountTokens: [aliceToken],
            email: "bob@x.com"
        ))
        XCTAssertFalse(StoreManager.ownsLocalSubscription(
            appAccountTokens: [nil],
            email: "alice@x.com"
        ))
    }
}
