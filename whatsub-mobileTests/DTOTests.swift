import XCTest
@testable import whatsub_mobile

final class DTOTests: XCTestCase {
    func testVerifyCodeResponseDecodes() throws {
        let json = #"{"sessionToken":"abc123","expiresAt":1779999999999}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(VerifyCodeResponse.self, from: json)
        XCTAssertEqual(resp.sessionToken, "abc123")
        XCTAssertEqual(resp.expiresAt, 1_779_999_999_999)
    }

    func testMeResponseDecodesWithoutIsAdmin() throws {
        let json = #"{"email":"a@b.com","hasActiveLicense":true}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(MeResponse.self, from: json)
        XCTAssertEqual(resp.email, "a@b.com")
        XCTAssertTrue(resp.hasActiveLicense)
        XCTAssertNil(resp.isAdmin)
    }

    // A cross-platform web (Alipay) subscriber: no StoreKit sub, but the
    // server-combined hasActiveSubscription is true. The badge + upsell gating
    // keys off this field so the user isn't mislabeled 免费版 or double-charged.
    func testMeResponseWebSubscriberHasActiveSubscriptionButNotIosSub() throws {
        let json = #"{"email":"a@b.com","hasActiveLicense":false,"iosSubActive":false,"hasActiveSubscription":true}"#
            .data(using: .utf8)!
        let resp = try JSONDecoder().decode(MeResponse.self, from: json)
        XCTAssertFalse(resp.hasActiveLicense)
        XCTAssertEqual(resp.iosSubActive, false)
        XCTAssertEqual(resp.hasActiveSubscription, true)
    }

    // An older backend that omits the field → nil (treated as not-subscribed).
    func testMeResponseDecodesWithoutHasActiveSubscription() throws {
        let json = #"{"email":"a@b.com","hasActiveLicense":false}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(MeResponse.self, from: json)
        XCTAssertNil(resp.hasActiveSubscription)
    }

    func testMeResponseDecodesBuyoutProLlmEntitlements() throws {
        let json = #"{"email":"a@b.com","hasActiveLicense":true,"llmEntitlements":{"tier":"buyout_pro","managedRelay":true,"byok":true,"tokenTopups":true}}"#
            .data(using: .utf8)!
        let resp = try JSONDecoder().decode(MeResponse.self, from: json)
        XCTAssertEqual(resp.llmEntitlements?.tier, .buyoutPro)
        XCTAssertTrue(resp.llmEntitlements?.managedRelay == true)
        XCTAssertTrue(resp.llmEntitlements?.byok == true)
        XCTAssertTrue(resp.llmEntitlements?.tokenTopups == true)
    }

    func testMeResponseWithoutLlmEntitlementsIsBackwardCompatible() throws {
        let json = #"{"email":"a@b.com","hasActiveLicense":false}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(MeResponse.self, from: json)
        XCTAssertNil(resp.llmEntitlements)
    }

    func testTokenTopupWireModelsDecode() throws {
        let catalog = try JSONDecoder().decode(
            TokenTopupCatalogResponse.self,
            from: #"{"products":[{"id":"whatsub_token_5m","tokens":5000000,"priceCny":"45.00"}]}"#.data(using: .utf8)!
        )
        XCTAssertEqual(catalog.products.first?.id, "whatsub_token_5m")
        XCTAssertEqual(catalog.products.first?.tokens, 5_000_000)

        let wallet = try JSONDecoder().decode(
            TokenWallet.self,
            from: #"{"monthlyUsed":120000,"monthlyLimit":5000000,"topupBalance":1000000,"topupFrozen":false,"periodResetAt":1788192000000}"#.data(using: .utf8)!
        )
        XCTAssertEqual(wallet.topupBalance, 1_000_000)

        let verify = try JSONDecoder().decode(
            VerifyPurchaseResponse.self,
            from: #"{"ok":true,"credited":false,"topupBalance":1000000,"topupFrozen":false}"#.data(using: .utf8)!
        )
        XCTAssertEqual(verify.credited, false)
    }

    func testSessionValidity() {
        let future = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        let past = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        XCTAssertTrue(Session(email: "a@b.com", sessionToken: "t", expiresAt: future).isValid)
        XCTAssertFalse(Session(email: "a@b.com", sessionToken: "t", expiresAt: past).isValid)
    }
}
