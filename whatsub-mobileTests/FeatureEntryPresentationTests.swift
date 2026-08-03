import XCTest
@testable import whatsub_mobile

final class FeatureEntryPresentationTests: XCTestCase {
    func testTrialBadgeCopyForEveryPresentationState() {
        XCTAssertNil(FeatureEntryPresentation.normal.badgeText)
        XCTAssertEqual(FeatureEntryPresentation.freeTrial.badgeText, "免费体验 1 次")
        XCTAssertEqual(FeatureEntryPresentation.continueTrial.badgeText, "继续免费体验")
        XCTAssertNil(FeatureEntryPresentation.subscriptionRequired.badgeText)
        XCTAssertNil(FeatureEntryPresentation.temporarilyUnavailable.badgeText)
    }

    func testOnlyConsumedPresentationRequiresSubscription() {
        XCTAssertFalse(FeatureEntryPresentation.normal.requiresSubscription)
        XCTAssertFalse(FeatureEntryPresentation.freeTrial.requiresSubscription)
        XCTAssertFalse(FeatureEntryPresentation.continueTrial.requiresSubscription)
        XCTAssertTrue(FeatureEntryPresentation.subscriptionRequired.requiresSubscription)
        XCTAssertFalse(FeatureEntryPresentation.temporarilyUnavailable.requiresSubscription)
    }
}
