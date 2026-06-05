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

    func testSessionValidity() {
        let future = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        let past = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        XCTAssertTrue(Session(email: "a@b.com", sessionToken: "t", expiresAt: future).isValid)
        XCTAssertFalse(Session(email: "a@b.com", sessionToken: "t", expiresAt: past).isValid)
    }
}
