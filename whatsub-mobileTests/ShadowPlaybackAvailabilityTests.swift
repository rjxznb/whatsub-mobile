import XCTest
@testable import whatsub_mobile

final class ShadowPlaybackAvailabilityTests: XCTestCase {
    func testResolveMapsOSSURLsBeforeYouTubeAvailability() {
        let ossAudioURL = URL(string: "https://cdn.example.com/library/audio.m4a")!
        let ossVideoURL = URL(string: "https://cdn.example.com/library/video.mp4")!

        let cases: [(name: String, audioURL: URL?, videoURL: URL?, hasYouTube: Bool, expected: ShadowPlaybackSource)] = [
            ("audio-only OSS wins over YouTube", ossAudioURL, nil, true, .oss),
            ("video-only OSS is available", nil, ossVideoURL, false, .oss),
            ("YouTube is used when no OSS URL exists", nil, nil, true, .youtube),
            ("no source is unavailable", nil, nil, false, .unavailable),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ShadowPlaybackSource.resolve(
                    audioURL: testCase.audioURL,
                    videoURL: testCase.videoURL,
                    hasYouTube: testCase.hasYouTube
                ),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testYouTubeUsesSupportedOriginalAudioRates() {
        XCTAssertEqual(ShadowPlaybackSource.youtube.availableRates, [0.5, 0.75, 1.0])
    }

    func testOSSRetainsExistingOriginalAudioRates() {
        XCTAssertEqual(ShadowPlaybackSource.oss.availableRates, [0.5, 0.65, 0.8, 1.0])
    }
}
