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
    case invalidAnalysisCue = "invalid_analysis_cue"
    case invalidSSE = "invalid_sse"
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
    let jobsAhead: Int?
    let estimatedStartSeconds: Int?

    init(
        jobId: String,
        status: ManagedAnalysisJobStatus,
        tier: ManagedAnalysisTier,
        createdAt: Int64,
        updatedAt: Int64,
        completedCues: Int,
        totalCues: Int,
        tokensIn: Int,
        tokensOut: Int,
        errorCode: ManagedAnalysisFailureCode?,
        resultEntryId: String?,
        jobsAhead: Int? = nil,
        estimatedStartSeconds: Int? = nil
    ) {
        self.jobId = jobId
        self.status = status
        self.tier = tier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedCues = completedCues
        self.totalCues = totalCues
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.errorCode = errorCode
        self.resultEntryId = resultEntryId
        self.jobsAhead = jobsAhead
        self.estimatedStartSeconds = estimatedStartSeconds
    }

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
            return .init(label: "排队中", detail: "关闭页面后会继续解析", canCancel: true, canResume: false, entryID: provisionalEntryID)
        case .running:
            return .init(
                label: "解析中 \(completedCues)/\(totalCues)",
                detail: nil, canCancel: true, canResume: false, entryID: provisionalEntryID
            )
        case .pausedQuota:
            let detail = errorCode == .freeUsedUp
                ? "免费体验额度已用完；订阅 Pro 后可继续"
                : "额度恢复后可继续"
            return .init(label: "额度不足，已暂停", detail: detail, canCancel: true, canResume: true, entryID: provisionalEntryID)
        case .completed:
            return .init(label: "已完成", detail: nil, canCancel: false, canResume: false, entryID: resultEntryId)
        case .failed:
            let detail: String
            switch errorCode {
            case .freeUsedUp: detail = "免费体验额度已用完"
            case .quotaExceeded: detail = "本月 AI 额度不足"
            case .upstreamUnavailable: detail = "AI 服务暂时不可用"
            case .invalidAnalysisCue, .invalidSSE: detail = "AI 返回格式异常"
            case .videoTooLong: detail = "视频超过当前方案时长限制"
            case .durationUnknown: detail = "无法确认视频时长"
            case nil: detail = "解析任务未完成"
            }
            return .init(label: "解析失败", detail: detail, canCancel: false, canResume: true, entryID: provisionalEntryID)
        case .cancelled:
            return .init(label: "已取消", detail: nil, canCancel: false, canResume: true, entryID: provisionalEntryID)
        }
    }

    var libraryProgressLabel: String? {
        let progressPrefix = completedCues > 0 ? "部分解析" : "仅英文"
        switch status {
        case .queued: return "等待 AI 解析"
        case .running: return "AI 解析中 · \(completedCues)/\(totalCues)"
        case .pausedQuota: return "\(progressPrefix) · 解析已暂停"
        case .failed: return "\(progressPrefix) · AI 解析失败"
        case .cancelled: return "\(progressPrefix) · 已停止"
        case .completed: return nil
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

enum ManagedAnalysisStreamError: Error, Equatable {
    case forbidden
    case admissionRejected(status: Int, retryAfterSeconds: Int?)
    case unsupported
}

enum ManagedAnalysisStreamMode: String, Equatable {
    case snapshot
    case replay
}

enum ManagedAnalysisCuePayloadType: String, Codable, Equatable {
    case cue
}

struct ManagedAnalysisStreamCue: Codable, Equatable {
    let type: ManagedAnalysisCuePayloadType
    let index: Int
    let time: Double
    let endTime: Double
    let text: String
    let translation: String
    let isKeyPoint: Bool
    let highlightWords: [String]
    let keyNotes: [String: String]
    let highlightTranslations: [String: String]
}

struct ManagedAnalysisPersistedEvent<Payload>: Codable, Equatable
where Payload: Codable & Equatable {
    let eventId: Int64
    let jobId: String
    let eventType: String
    let batchIndex: Int?
    let attempt: Int?
    let cueIndex: Int?
    let payload: Payload
    let createdAt: Int64
}

struct ManagedAnalysisBatchResetPayload: Codable, Equatable {
    let abandonedAttempt: Int
    let nextAttempt: Int?
}

struct ManagedAnalysisBatchCommittedPayload: Codable, Equatable {
    let batchIndex: Int
    let attempt: Int
    let completedCues: Int
}

enum ManagedAnalysisPhase: String, Codable, Equatable {
    case cues
    case summary
    case finalize
}

struct ManagedAnalysisPhasePayload: Codable, Equatable {
    let phase: ManagedAnalysisPhase
}

struct ManagedAnalysisJobStatePayload: Codable, Equatable {
    let status: ManagedAnalysisJobStatus
    let errorCode: String?
    let resultEntryId: String?
}

typealias ManagedAnalysisCueStreamEvent = ManagedAnalysisPersistedEvent<ManagedAnalysisStreamCue>
typealias ManagedAnalysisBatchResetStreamEvent = ManagedAnalysisPersistedEvent<ManagedAnalysisBatchResetPayload>
typealias ManagedAnalysisBatchCommittedStreamEvent = ManagedAnalysisPersistedEvent<ManagedAnalysisBatchCommittedPayload>
typealias ManagedAnalysisPhaseStreamEvent = ManagedAnalysisPersistedEvent<ManagedAnalysisPhasePayload>
typealias ManagedAnalysisJobStateStreamEvent = ManagedAnalysisPersistedEvent<ManagedAnalysisJobStatePayload>

extension ManagedAnalysisPersistedEvent where Payload == ManagedAnalysisStreamCue {
    var cue: ManagedAnalysisStreamCue { payload }
}

extension ManagedAnalysisPersistedEvent where Payload == ManagedAnalysisBatchResetPayload {
    var abandonedAttempt: Int { payload.abandonedAttempt }
    var nextAttempt: Int? { payload.nextAttempt }
}

extension ManagedAnalysisPersistedEvent where Payload == ManagedAnalysisBatchCommittedPayload {
    var completedCues: Int { payload.completedCues }
}

extension ManagedAnalysisPersistedEvent where Payload == ManagedAnalysisPhasePayload {
    var phase: ManagedAnalysisPhase { payload.phase }
}

extension ManagedAnalysisPersistedEvent where Payload == ManagedAnalysisJobStatePayload {
    var status: ManagedAnalysisJobStatus { payload.status }
    var errorCode: String? { payload.errorCode }
    var resultEntryId: String? { payload.resultEntryId }
}

struct ManagedAnalysisConnectedEvent: Equatable {
    let jobId: String
    let retryMilliseconds: Int?
}

struct ManagedAnalysisStreamCurrentAttempt: Codable, Equatable {
    let batchIndex: Int
    let attempt: Int
    let cues: [ManagedAnalysisCueStreamEvent]
}

struct ManagedAnalysisStreamSnapshot: Codable, Equatable {
    let jobId: String
    let status: ManagedAnalysisJobStatus
    let totalCues: Int
    let completedCues: Int
    let completedBatchCursor: Int
    let latestEventId: Int64?
    let errorCode: String?
    let jobsAhead: Int?
    let estimatedStartSeconds: Int?
    let currentAttempt: ManagedAnalysisStreamCurrentAttempt?
}

enum ManagedAnalysisResyncReason: String, Codable, Equatable {
    case cursorExpired = "cursor_expired"
}

struct ManagedAnalysisResyncEvent: Codable, Equatable {
    let reason: ManagedAnalysisResyncReason
}

enum ManagedAnalysisStreamEvent: Equatable {
    case connected(ManagedAnalysisConnectedEvent)
    case snapshot(ManagedAnalysisStreamSnapshot)
    case cue(ManagedAnalysisCueStreamEvent)
    case batchReset(ManagedAnalysisBatchResetStreamEvent)
    case batchCommitted(ManagedAnalysisBatchCommittedStreamEvent)
    case phase(ManagedAnalysisPhaseStreamEvent)
    case jobState(ManagedAnalysisJobStateStreamEvent)
    case resync(ManagedAnalysisResyncEvent)

    var eventID: Int64? {
        switch self {
        case .connected, .snapshot, .resync:
            return nil
        case let .cue(event):
            return event.eventId
        case let .batchReset(event):
            return event.eventId
        case let .batchCommitted(event):
            return event.eventId
        case let .phase(event):
            return event.eventId
        case let .jobState(event):
            return event.eventId
        }
    }

    static func decode(
        _ message: ManagedAnalysisSSEMessage,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> ManagedAnalysisStreamEvent? {
        guard let eventName = message.event else { return nil }

        switch eventName {
        case "connected":
            struct Payload: Decodable { let jobId: String }
            guard message.id == nil else {
                throw parseError(for: message, eventName: eventName)
            }
            let payload: Payload = try decodePayload(message, eventName: eventName, using: decoder)
            return .connected(.init(jobId: payload.jobId, retryMilliseconds: message.retryMilliseconds))

        case "snapshot":
            guard message.id == nil else {
                throw parseError(for: message, eventName: eventName)
            }
            let snapshot: ManagedAnalysisStreamSnapshot = try decodePayload(
                message,
                eventName: eventName,
                using: decoder
            )
            return .snapshot(snapshot)

        case "cue":
            let event: ManagedAnalysisCueStreamEvent = try decodePersisted(
                message,
                eventName: eventName,
                using: decoder
            )
            guard event.batchIndex != nil,
                  event.attempt != nil,
                  let cueIndex = event.cueIndex,
                  cueIndex == event.cue.index else {
                throw parseError(for: message, eventName: eventName)
            }
            return .cue(event)

        case "batch_reset":
            let event: ManagedAnalysisBatchResetStreamEvent = try decodePersisted(
                message,
                eventName: eventName,
                using: decoder
            )
            guard event.batchIndex != nil,
                  let attempt = event.attempt,
                  attempt == event.abandonedAttempt,
                  event.cueIndex == nil else {
                throw parseError(for: message, eventName: eventName)
            }
            return .batchReset(event)

        case "batch_committed":
            let event: ManagedAnalysisBatchCommittedStreamEvent = try decodePersisted(
                message,
                eventName: eventName,
                using: decoder
            )
            guard event.batchIndex == event.payload.batchIndex,
                  event.attempt == event.payload.attempt,
                  event.cueIndex == nil else {
                throw parseError(for: message, eventName: eventName)
            }
            return .batchCommitted(event)

        case "phase":
            let event: ManagedAnalysisPhaseStreamEvent = try decodePersisted(
                message,
                eventName: eventName,
                using: decoder
            )
            return .phase(event)

        case "job_state":
            let event: ManagedAnalysisJobStateStreamEvent = try decodePersisted(
                message,
                eventName: eventName,
                using: decoder
            )
            return .jobState(event)

        case "resync":
            guard message.id == nil else {
                throw parseError(for: message, eventName: eventName)
            }
            let resync: ManagedAnalysisResyncEvent = try decodePayload(
                message,
                eventName: eventName,
                using: decoder
            )
            return .resync(resync)

        default:
            // Future server events must not move the recoverable cursor until
            // this client understands and applies their state transition.
            return nil
        }
    }

    private static func decodePersisted<Payload>(
        _ message: ManagedAnalysisSSEMessage,
        eventName: String,
        using decoder: JSONDecoder
    ) throws -> ManagedAnalysisPersistedEvent<Payload>
    where Payload: Codable & Equatable {
        let event: ManagedAnalysisPersistedEvent<Payload> = try decodePayload(
            message,
            eventName: eventName,
            using: decoder
        )
        guard let messageID = message.id,
              messageID == event.eventId,
              event.eventType == eventName else {
            throw parseError(for: message, eventName: eventName)
        }
        return event
    }

    private static func decodePayload<Payload: Decodable>(
        _ message: ManagedAnalysisSSEMessage,
        eventName: String,
        using decoder: JSONDecoder
    ) throws -> Payload {
        do {
            return try decoder.decode(Payload.self, from: Data(message.data.utf8))
        } catch {
            throw parseError(for: message, eventName: eventName)
        }
    }

    private static func parseError(
        for message: ManagedAnalysisSSEMessage,
        eventName: String
    ) -> ManagedAnalysisSSEParseError {
        .malformedJSON(event: eventName, eventID: message.id)
    }
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
    func events(
        id: String,
        afterEventID: Int64?,
        mode: ManagedAnalysisStreamMode,
        token: String
    ) -> AsyncThrowingStream<ManagedAnalysisStreamEvent, Error>
}

extension ManagedAnalysisClientProtocol {
    func events(
        id: String,
        afterEventID: Int64?,
        mode: ManagedAnalysisStreamMode,
        token: String
    ) -> AsyncThrowingStream<ManagedAnalysisStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ManagedAnalysisStreamError.unsupported)
        }
    }
}
