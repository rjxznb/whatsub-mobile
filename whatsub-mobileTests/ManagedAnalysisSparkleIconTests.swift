import XCTest
@testable import whatsub_mobile

final class ManagedAnalysisSparkleIconTests: XCTestCase {
    func testPollingAnimatesWithSpecifiedEndpoints() {
        let value = ManagedAnalysisSparklePresentation(
            isPolling: true,
            reduceMotion: false
        )

        XCTAssertTrue(value.shouldAnimate)
        XCTAssertEqual(value.restingScale, 0.92, accuracy: 0.001)
        XCTAssertEqual(value.expandedScale, 1.10, accuracy: 0.001)
        XCTAssertEqual(value.restingOpacity, 0.55, accuracy: 0.001)
        XCTAssertEqual(value.expandedOpacity, 1.0, accuracy: 0.001)
    }

    func testNonPollingIsStatic() {
        let value = ManagedAnalysisSparklePresentation(
            isPolling: false,
            reduceMotion: false
        )

        XCTAssertFalse(value.shouldAnimate)
        XCTAssertEqual(value.restingScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(value.expandedScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(value.restingOpacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(value.expandedOpacity, 1.0, accuracy: 0.001)
    }

    func testReduceMotionOverridesPolling() {
        let value = ManagedAnalysisSparklePresentation(
            isPolling: true,
            reduceMotion: true
        )

        XCTAssertFalse(value.shouldAnimate)
        XCTAssertEqual(value.restingScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(value.expandedScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(value.restingOpacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(value.expandedOpacity, 1.0, accuracy: 0.001)
    }
}
