import Foundation

enum AnalysisStreamStage: String, Codable, Equatable {
    case preparingRequest = "preparing_request"
    case connecting
    case responseOpen = "response_open"
    case firstContent = "first_content"
    case parsing
    case batchComplete = "batch_complete"
}

struct AnalysisStreamEvent: Equatable {
    let stage: AnalysisStreamStage
    let batch: Int
    let parsedCues: Int
}

final class AnalysisStreamDiagnosticTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = AnalysisStreamEvent(stage: .preparingRequest, batch: 0, parsedCues: 0)

    func record(_ event: AnalysisStreamEvent) {
        lock.lock()
        latest = event
        lock.unlock()
    }

    func snapshot() -> AnalysisStreamEvent {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

struct BYOKNoProgressTimeoutError: Error {
    let event: AnalysisStreamEvent
}

extension AnalysisDiagnosticReport {
    static func byok(
        stage: AnalysisStreamStage,
        elapsedSeconds: Int,
        providerHost: String,
        model: String,
        batch: Int,
        parsedCues: Int,
        appVersion: String? = nil,
        appBuild: String? = nil
    ) -> AnalysisDiagnosticReport {
        let version = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let build = appBuild
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        let lines = [
            "category=byok-stream",
            "app=\(version) (\(build))",
            "stage=\(stage.rawValue)",
            "elapsedSec=\(elapsedSeconds)",
            "providerHost=\(providerHost)",
            "model=\(model)",
            "batch=\(batch)",
            "parsedCues=\(parsedCues)",
        ]
        return AnalysisDiagnosticReport(category: "byok-stream", summary: lines.joined(separator: "\n"))
    }
}
