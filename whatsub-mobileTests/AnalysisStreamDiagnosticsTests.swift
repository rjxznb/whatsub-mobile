import XCTest
@testable import whatsub_mobile

final class AnalysisStreamDiagnosticsTests: XCTestCase {
    func testBYOKReportDescribesStageWithoutProviderSecrets() {
        let report = AnalysisDiagnosticReport.byok(
            stage: .responseOpen,
            elapsedSeconds: 90,
            providerHost: "api.provider.example",
            model: "safe-model",
            batch: 0,
            parsedCues: 0,
            appVersion: "1.2.3",
            appBuild: "456"
        )

        XCTAssertEqual(report.category, "byok-stream")
        for expected in [
            "app=1.2.3 (456)", "stage=response_open", "elapsedSec=90",
            "providerHost=api.provider.example", "model=safe-model",
            "batch=0", "parsedCues=0",
        ] {
            XCTAssertTrue(report.copyText.contains(expected), "missing \(expected)")
        }
        XCTAssertFalse(report.copyText.contains("https://"))
        XCTAssertFalse(report.copyText.contains("/v1"))
        XCTAssertFalse(report.copyText.lowercased().contains("bearer"))
    }
}
