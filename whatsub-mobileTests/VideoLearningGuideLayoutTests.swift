import XCTest
@testable import whatsub_mobile

final class VideoLearningGuideLayoutTests: XCTestCase {
    func testExpandedGuideHeightAdaptsWithinReadableBounds() {
        XCTAssertEqual(VideoLearningGuideLayout.maxExpandedHeight(for: 667), 220)
        XCTAssertEqual(
            VideoLearningGuideLayout.maxExpandedHeight(for: 844),
            270.08,
            accuracy: 0.01
        )
        XCTAssertEqual(VideoLearningGuideLayout.maxExpandedHeight(for: 1_366), 340)
    }

    func testExpandedGuideUsesBoundedScrollBelowPersistentHeader() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/VideoLearningGuideCard.swift"
        ), encoding: .utf8)

        let toggle = try XCTUnwrap(source.range(of: "isExpanded.toggle()"))
        let scroll = try XCTUnwrap(source.range(
            of: "ScrollView(.vertical, showsIndicators: true)"
        ))
        XCTAssertLessThan(toggle.lowerBound, scroll.lowerBound)
        XCTAssertTrue(source.contains(
            ".frame(maxHeight: expandedContentMaxHeight)"
        ))
    }
}
