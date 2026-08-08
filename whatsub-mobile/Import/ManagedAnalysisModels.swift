import Foundation

struct ManagedAnalysisCue: Codable, Equatable {
    let index: Int
    let time: Double
    let endTime: Double
    let text: String

    init(index: Int, time: Double, endTime: Double, text: String) {
        self.index = index
        self.time = time
        self.endTime = endTime
        self.text = text
    }

    init(cue: Cue) {
        self.init(index: cue.index, time: cue.time, endTime: cue.endTime, text: cue.text)
    }
}

struct ManagedAnalysisCreateRequest: Codable, Equatable {
    let idempotencyKey: String
    let youtubeId: String
    let sourceUrl: String
    let title: String
    let durationSec: Int
    let cues: [ManagedAnalysisCue]
    let transcriptSrt: String
    let thumbData: String?
}

enum ManagedAnalysisJobStatus: String, Codable, Equatable {
    case queued
    case running
    case pausedQuota = "paused_quota"
    case completed
    case failed
    case cancelled
}

enum ManagedAnalysisTier: String, Codable, Equatable {
    case free
    case pro
}

enum ManagedAnalysisFailureCode: String, Codable, Equatable {
    case freeUsedUp = "free_used_up"
    case quotaExceeded = "quota_exceeded"
    case upstreamUnavailable = "upstream_unavailable"
    case videoTooLong = "video_too_long"
    case durationUnknown = "duration_unknown"
}

struct ManagedAnalysisJob: Codable, Equatable, Identifiable {
    let jobId: String
    let status: ManagedAnalysisJobStatus
    let tier: ManagedAnalysisTier
    let createdAt: Int64
    let updatedAt: Int64
    let completedCues: Int
    let totalCues: Int
    let tokensIn: Int
    let tokensOut: Int
    let errorCode: ManagedAnalysisFailureCode?
    let resultEntryId: String?

    var id: String { jobId }
    var progress: Double {
        guard totalCues > 0 else { return status == .completed ? 1 : 0 }
        return min(max(Double(completedCues) / Double(totalCues), 0), 1)
    }
}

enum ManagedAnalysisClientError: Error, Equatable {
    case network(String)
    case unauthorized
    case notFound
    case invalidState
    case durationUnknown
    case videoTooLong
    case freeUsedUp
    case quotaExceeded
    case upstreamUnavailable
    case queueLimit
    case serverBusy(retryable: Bool)
    case invalidResponse(String)
    case server(status: Int, code: String?)
}

enum ManagedEntitlementState: Equatable {
    case freshFree
    case freshPro
    case unknown
}

enum ManagedAnalysisPolicy: Equatable {
    case durationUnknown
    case videoTooLong(duration: Int, limit: Int)
    case freeUsedUp
    case quotaExceeded
    case upstreamUnavailable
    case serverBusy
    case queueLimit
}

protocol ManagedAnalysisClientProtocol {
    func createJob(
        _ request: ManagedAnalysisCreateRequest,
        token: String
    ) async throws -> ManagedAnalysisJob
    func job(id: String, token: String) async throws -> ManagedAnalysisJob
    func jobs(token: String) async throws -> [ManagedAnalysisJob]
    func cancel(id: String, token: String) async throws -> ManagedAnalysisJob
    func resume(id: String, token: String) async throws -> ManagedAnalysisJob
}
