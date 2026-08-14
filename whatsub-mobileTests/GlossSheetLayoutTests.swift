import XCTest
@testable import whatsub_mobile

final class GlossSheetLayoutTests: XCTestCase {
    func testGlossStartsAtReadableFractionDetent() {
        XCTAssertEqual(GlossSheet.defaultDetent, .fraction(0.65))
    }

    func testLayoutKeepsActionsVisibleAndExpandsForDeepGloss() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/GlossSheet.swift"
        ), encoding: .utf8)

        let save = try XCTUnwrap(source.range(of: "if showsCollectionControl"))
        let deepContent = try XCTUnwrap(source.range(of: "deepGlossContent"))
        XCTAssertLessThan(save.lowerBound, deepContent.lowerBound)
        XCTAssertTrue(source.contains(
            "selectedDetent: PresentationDetent = Self.defaultDetent"
        ))
        XCTAssertTrue(source.contains(
            ".presentationDetents([Self.defaultDetent, .large]"
        ))
        XCTAssertTrue(source.contains("selectedDetent = .large"))
    }

    func testDeepGlossDecorationsAreHiddenFromVoiceOver() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/GlossSheet.swift"
        ), encoding: .utf8)

        let hiddenDecorationCount = source
            .components(separatedBy: ".accessibilityHidden(true)")
            .count - 1
        XCTAssertGreaterThanOrEqual(hiddenDecorationCount, 2)
    }
}
