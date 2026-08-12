import XCTest
@testable import whatsub_mobile

final class GlossSheetLayoutTests: XCTestCase {
    func testGlossStartsAtCompactBottomDetent() {
        XCTAssertEqual(GlossSheet.compactDetent, .height(340))
    }

    func testCompactLayoutPlacesBothActionsBeforeExpandableContent() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/GlossSheet.swift"
        ), encoding: .utf8)

        let save = try XCTUnwrap(source.range(of: "if showsCollectionControl"))
        let deepContent = try XCTUnwrap(source.range(of: "deepGlossContent"))
        XCTAssertLessThan(save.lowerBound, deepContent.lowerBound)
        XCTAssertTrue(source.contains("selectedDetent: PresentationDetent = Self.compactDetent"))
    }
}
