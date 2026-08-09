import XCTest
@testable import whatsub_mobile

final class ShadowPlaybackAvailabilityTests: XCTestCase {
    func testResolvePrefersOSSWhenBothSourcesAreAvailable() {
        XCTAssertEqual(
            ShadowPlaybackSource.resolve(hasOSS: true, hasYouTube: true),
            .oss
        )
    }

    func testResolveFallsBackToYouTubeWhenOSSIsUnavailable() {
        XCTAssertEqual(
            ShadowPlaybackSource.resolve(hasOSS: false, hasYouTube: true),
            .youtube
        )
    }

    func testResolveIsUnavailableWhenNeitherSourceIsAvailable() {
        XCTAssertEqual(
            ShadowPlaybackSource.resolve(hasOSS: false, hasYouTube: false),
            .unavailable
        )
    }

    func testYouTubeUsesSupportedOriginalAudioRates() {
        XCTAssertEqual(ShadowPlaybackSource.youtube.availableRates, [0.5, 0.75, 1.0])
    }

    func testOSSRetainsExistingOriginalAudioRates() {
        XCTAssertEqual(ShadowPlaybackSource.oss.availableRates, [0.5, 0.65, 0.8, 1.0])
    }
}
