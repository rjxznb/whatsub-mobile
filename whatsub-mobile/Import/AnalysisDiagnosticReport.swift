import Foundation

struct AnalysisDiagnosticReport: Equatable {
    let category: String
    let summary: String

    var copyText: String { summary }

    static func managed(
        request: ManagedAnalysisCreateRequest,
        encodedBytes: Int,
        status: Int,
        code: String?,
        diagnosticCode: String?,
        diagnosticId: String?,
        appVersion: String? = nil,
        appBuild: String? = nil
    ) -> AnalysisDiagnosticReport {
        let version = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let build = appBuild
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        let finalCueEnd = request.cues.last.map { String(format: "%.3f", $0.endTime) } ?? "none"
        let thumbnailBytes: String
        if let thumbnail = request.thumbData,
           let decoded = Data(base64Encoded: thumbnail) {
            thumbnailBytes = String(decoded.count)
        } else {
            thumbnailBytes = "none"
        }
        let lines = [
            "category=managed-submit",
            "app=\(version) (\(build))",
            "http=\(status)",
            "server=\(code ?? "none")",
            "diagnostic=\(diagnosticCode ?? "none")",
            "diagnosticId=\(diagnosticId ?? "none")",
            "videoId=\(request.youtubeId)",
            "durationSec=\(request.durationSec)",
            "cueCount=\(request.cues.count)",
            "finalCueEnd=\(finalCueEnd)",
            "requestBytes=\(encodedBytes)",
            "thumbnailBytes=\(thumbnailBytes)",
        ]
        return AnalysisDiagnosticReport(category: "managed-submit", summary: lines.joined(separator: "\n"))
    }
}
