import XCTest
@testable import whatsub_mobile

final class FeatureSessionGateTests: XCTestCase {
    func testGrantCannotBeReusedAcrossConversationFeatures() {
        let quickChat = FeatureAccessGrant(feature: .quickChat, access: .trial)
        let roleplay = FeatureAccessGrant(feature: .videoRoleplay, access: .trial)

        XCTAssertTrue(quickChat.matches(.quickChat))
        XCTAssertFalse(quickChat.matches(.videoRoleplay))
        XCTAssertTrue(roleplay.matches(.videoRoleplay))
        XCTAssertFalse(roleplay.matches(.quickChat))
    }
}
