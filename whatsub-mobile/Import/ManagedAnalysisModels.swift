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

struct ManagedAnalysisJobPresentation: Equatable {
    let label: String
    let detail: String?
    let canCancel: Bool
    let canResume: Bool
    let entryID: String?
}

extension ManagedAnalysisJob {
    /// New servers create the English-only Library entry atomically with the
    /// job. Older servers may still return nil, in which case the import view
    /// simply keeps its existing job-status UI instead of navigating nowhere.
    var provisionalEntryID: String? {
        guard let resultEntryId,
              !resultEntryId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return resultEntryId
    }

    var presentation: ManagedAnalysisJobPresentation {
        switch status {
        case .queued:
            return .init(label: "排队中", detail: "关闭页面后会继续解析", canCancel: true, canResume: false, entryID: nil)
        case .running:
            return .init(
                label: "解析中 \(completedCues)/\(totalCues)",
                detail: nil, canCancel: true, canResume: false, entryID: nil
            )
        case .pausedQuota:
            let detail = errorCode == .freeUsedUp
                ? "免费体验额度已用完；订阅 Pro 后可继续"
                : "额度恢复后可继续"
            return .init(label: "额度不足，已暂停", detail: detail, canCancel: true, canResume: true, entryID: nil)
        case .completed:
            return .init(label: "已完成", detail: nil, canCancel: false, canResume: false, entryID: resultEntryId)
        case .failed:
            let detail: String
            switch errorCode {
            case .freeUsedUp: detail = "免费体验额度已用完"
            case .quotaExceeded: detail = "本月 AI 额度不足"
            case .upstreamUnavailable: detail = "AI 服务暂时不可用"
            case .videoTooLong: detail = "视频超过当前方案时长限制"
            case .durationUnknown: detail = "无法确认视频时长"
            case nil: detail = "解析任务未完成"
            }
            return .init(label: "解析失败", detail: detail, canCancel: false, canResume: false, entryID: nil)
        case .cancelled:
            return .init(label: "已取消", detail: nil, canCancel: false, canResume: false, entryID: nil)
        }
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
    case server(
        status: Int,
        code: String?,
        diagnosticCode: String?,
        diagnosticId: String?
    )
}

struct ManagedAnalysisCompletedBatch: Decodable {
    let batchIndex: Int
    let subtitles: [Cue]
}

struct ManagedAnalysisResultsPage: Decodable {
    let jobId: String
    let entryId: String
    let status: ManagedAnalysisJobStatus
    let completedCues: Int
    let totalCues: Int
    let nextBatchCursor: Int
    let batches: [ManagedAnalysisCompletedBatch]
    let errorCode: ManagedAnalysisFailureCode?
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
    func results(id: String, afterBatch: Int, token: String) async throws -> ManagedAnalysisResultsPage
    func cancel(id: String, token: String) async throws -> ManagedAnalysisJob
    func resume(id: String, token: String) async throws -> ManagedAnalysisJob
}
