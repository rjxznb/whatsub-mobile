import XCTest
@testable import whatsub_mobile

final class LlmEntitlementPolicyTests: XCTestCase {
    private var storedBYOK: LlmSettings {
        var settings = LlmSettings()
        settings.useManagedRelay = false
        settings.baseUrl = "https://provider.example/v1"
        settings.apiKey = "sk-secret"
        settings.baseUrl = "https://provider.example/v1"
        settings.model = "model"
        return settings
    }

    func testFourStateAllowedModes() {
        XCTAssertEqual(LlmEntitlementPolicy.allowedModes(for: .free), [.managedRelay])
        XCTAssertEqual(LlmEntitlementPolicy.allowedModes(for: .buyout), [.byok])
        XCTAssertEqual(LlmEntitlementPolicy.allowedModes(for: .pro), [.managedRelay])
        XCTAssertEqual(LlmEntitlementPolicy.allowedModes(for: .buyoutPro), [.managedRelay, .byok])
    }

    func testPersistedBYOKIsCoercedForProButNotDeleted() throws {
        let effective = LlmEntitlementPolicy.effectiveSettings(storedBYOK, entitlements: .pro)
        XCTAssertTrue(effective.useManagedRelay)
        XCTAssertEqual(storedBYOK.apiKey, "sk-secret")
    }

    func testBuyoutForcesBYOKAndBuyoutProPreservesSelection() {
        XCTAssertFalse(LlmEntitlementPolicy.effectiveSettings(
            LlmSettings(), entitlements: .buyout
        ).useManagedRelay)
        XCTAssertFalse(LlmEntitlementPolicy.effectiveSettings(
            storedBYOK, entitlements: .buyoutPro
        ).useManagedRelay)
        XCTAssertTrue(LlmEntitlementPolicy.effectiveSettings(
            LlmSettings(), entitlements: .buyoutPro
        ).useManagedRelay)
    }

    func testDisallowedModeThrowsStableError() {
        XCTAssertThrowsError(try LlmEntitlementPolicy.validateCall(
            settings: storedBYOK,
            entitlements: .free
        )) { error in
            XCTAssertEqual(error as? LlmEntitlementError, .byokNotEntitled)
        }
    }
}
