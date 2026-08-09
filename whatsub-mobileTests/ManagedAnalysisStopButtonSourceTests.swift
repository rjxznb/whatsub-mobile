import XCTest

final class ManagedAnalysisStopButtonSourceTests: XCTestCase {
    func testStopConfirmationIsOwnedByStopButtonInsteadOfDetailRoot() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let detail = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/LibraryDetailView.swift"), encoding: .utf8)
        let buttonURL = root.appendingPathComponent(
            "whatsub-mobile/Library/ManagedAnalysisStopButton.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: buttonURL.path))
        let button = try String(contentsOf: buttonURL, encoding: .utf8)
        XCTAssertFalse(detail.contains("confirmStopAnalysis"))
        XCTAssertFalse(detail.contains("停止 AI 解析？"))
        XCTAssertTrue(button.contains(".confirmationDialog("))
        XCTAssertTrue(button.contains("停止 AI 解析？"))
        XCTAssertTrue(button.contains("停止解析"))
        XCTAssertTrue(button.contains("已完成的翻译会保留"))
    }
}
