import XCTest
@testable import whatsub_mobile

final class LlmEntitlementStateTests: XCTestCase {
    @MainActor
    func testLogoutClearsEffectiveCapabilities() throws {
        let state = AppState()
        let future = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
        state.setSession(Session(email: "a@x.com", sessionToken: "session", expiresAt: future))
        let data = #"{"email":"a@x.com","hasActiveLicense":true,"llmEntitlements":{"tier":"buyout","managedRelay":false,"byok":true,"tokenTopups":false}}"#.data(using: .utf8)!
        state.currentUser = try JSONDecoder().decode(MeResponse.self, from: data)
        XCTAssertEqual(state.effectiveLlmEntitlements?.tier, .buyout)
        state.logout()
        XCTAssertNil(state.effectiveLlmEntitlements)
    }

    @MainActor
    func testDifferentSessionEmailCannotReuseCurrentUserCapabilities() throws {
        let state = AppState()
        let future = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
        state.setSession(Session(email: "b@x.com", sessionToken: "session", expiresAt: future))
        let data = #"{"email":"a@x.com","hasActiveLicense":true,"llmEntitlements":{"tier":"buyout","managedRelay":false,"byok":true,"tokenTopups":false}}"#.data(using: .utf8)!
        state.currentUser = try JSONDecoder().decode(MeResponse.self, from: data)
        XCTAssertNil(state.effectiveLlmEntitlements)
    }
}
