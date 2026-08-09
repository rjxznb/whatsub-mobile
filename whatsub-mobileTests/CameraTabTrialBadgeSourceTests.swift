import XCTest

final class CameraTabTrialBadgeSourceTests: XCTestCase {
    func testHeaderKeepsOnlyTheLiveSceneTrialBadge() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Camera/CameraTabView.swift"), encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: "FeatureTrialBadge(").count - 1, 1)
        XCTAssertTrue(source.contains("for: .liveScene"))
        XCTAssertFalse(source.contains("for: .photoAI"))
        XCTAssertTrue(source.contains("showPhotoTranslate = true"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"拍照翻译\")"))
    }
}
