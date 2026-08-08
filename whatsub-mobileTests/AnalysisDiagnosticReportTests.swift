import XCTest
@testable import whatsub_mobile

final class AnalysisDiagnosticReportTests: XCTestCase {
    func testManagedReportIncludesUsefulMetadataWithoutRequestSecrets() throws {
        let secretCue = "SUBTITLE-SENTINEL"
        let secretTitle = "TITLE-SENTINEL"
        let request = ManagedAnalysisCreateRequest(
            idempotencyKey: "IDEMPOTENCY-SENTINEL",
            youtubeId: "abcdefghijk",
            sourceUrl: "https://www.youtube.com/watch?v=abcdefghijk&secret=URL-SENTINEL",
            title: secretTitle,
            durationSec: 120,
            cues: [ManagedAnalysisCue(index: 0, time: 0.25, endTime: 118.75, text: secretCue)],
            transcriptSrt: "1\n00:00:00,250 --> 00:01:58,750\n\(secretCue)\n",
            thumbData: Data(repeating: 7, count: 12).base64EncodedString()
        )

        let report = AnalysisDiagnosticReport.managed(
            request: request,
            encodedBytes: 987,
            status: 400,
            code: "invalid_input",
            diagnosticCode: "cue_end_after_duration",
            diagnosticId: "abc123def456",
            appVersion: "1.2.3",
            appBuild: "456"
        )

        XCTAssertEqual(report.category, "managed-submit")
        for expected in [
            "app=1.2.3 (456)", "http=400", "server=invalid_input",
            "diagnostic=cue_end_after_duration", "diagnosticId=abc123def456",
            "videoId=abcdefghijk", "durationSec=120", "cueCount=1",
            "finalCueEnd=118.750", "requestBytes=987", "thumbnailBytes=12",
        ] {
            XCTAssertTrue(report.copyText.contains(expected), "missing \(expected)")
        }
        for forbidden in [
            secretCue, secretTitle, "IDEMPOTENCY-SENTINEL", "URL-SENTINEL",
            "youtube.com/watch", "https://",
        ] {
            XCTAssertFalse(report.copyText.contains(forbidden), "leaked \(forbidden)")
        }
    }

    func testManagedReportHandlesMissingThumbnailAndServerDiagnostics() {
        let request = ManagedAnalysisCreateRequest(
            idempotencyKey: "safe-key",
            youtubeId: "abcdefghijk",
            sourceUrl: "https://youtu.be/abcdefghijk",
            title: "Video",
            durationSec: 60,
            cues: [ManagedAnalysisCue(index: 0, time: 0, endTime: 1, text: "Hello")],
            transcriptSrt: "srt",
            thumbData: nil
        )

        let report = AnalysisDiagnosticReport.managed(
            request: request,
            encodedBytes: 300,
            status: 500,
            code: nil,
            diagnosticCode: nil,
            diagnosticId: nil,
            appVersion: "unknown",
            appBuild: "unknown"
        )

        XCTAssertTrue(report.copyText.contains("thumbnailBytes=none"))
        XCTAssertTrue(report.copyText.contains("server=none"))
        XCTAssertTrue(report.copyText.contains("diagnostic=none"))
    }
}
