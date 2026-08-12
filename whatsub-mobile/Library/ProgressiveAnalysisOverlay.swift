import Foundation

/// Merges only server-generated fields over an immutable English transcript.
/// Text, timing, ordering, and cue identity always remain client/server
/// caption-source authority rather than model authority.
struct ProgressiveAnalysisOverlay {
    private let baselineByIndex: [Int: Cue]
    private(set) var generatedByIndex: [Int: Cue] = [:]
    private var previewByKey: [ManagedAnalysisPreviewKey: Cue] = [:]

    init(baseline: [Cue]) {
        baselineByIndex = Dictionary(uniqueKeysWithValues: baseline.map { ($0.index, $0) })
    }

    var resolvedIndexes: Set<Int> {
        Set(generatedByIndex.keys).union(previewByKey.values.map(\.index))
    }

    mutating func merge(_ batches: [ManagedAnalysisCompletedBatch]) {
        for batch in batches {
            for cue in batch.subtitles where generatedByIndex[cue.index] == nil {
                guard accepts(cue) else { continue }
                generatedByIndex[cue.index] = cue
            }
            // Once `/results` exposes a batch, that durable layer is the only
            // authority for it. This also prevents committed previews from
            // being counted twice while replay catches up.
            previewByKey = previewByKey.filter { $0.key.batchIndex != batch.batchIndex }
        }
    }

    mutating func replacePreviews(
        _ previews: [ManagedAnalysisPreviewKey: ManagedAnalysisStreamCue]
    ) {
        var accepted: [ManagedAnalysisPreviewKey: Cue] = [:]
        for (key, preview) in previews where key.cueIndex == preview.index {
            var cue = Cue(
                index: preview.index,
                time: preview.time,
                endTime: preview.endTime,
                text: preview.text,
                translation: preview.translation
            )
            cue.isKeyPoint = preview.isKeyPoint
            cue.highlightWords = preview.highlightWords
            cue.keyNotes = preview.keyNotes
            cue.highlightTranslations = preview.highlightTranslations
            guard accepts(cue), generatedByIndex[cue.index] == nil else { continue }
            accepted[key] = cue
        }
        previewByKey = accepted
    }

    func displayedCues(from baseline: [Cue]) -> [Cue] {
        let previewsByIndex = previewByKey
            .sorted {
                if $0.key.batchIndex != $1.key.batchIndex {
                    return $0.key.batchIndex < $1.key.batchIndex
                }
                return $0.key.attempt < $1.key.attempt
            }
            .reduce(into: [Int: Cue]()) { result, item in
                result[item.value.index] = item.value
            }
        baseline.map { source in
            guard let generated = generatedByIndex[source.index] ?? previewsByIndex[source.index] else {
                return source
            }
            var displayed = source
            displayed.translation = generated.translation
            displayed.isKeyPoint = generated.isKeyPoint
            displayed.highlightWords = generated.highlightWords
            displayed.keyNotes = generated.keyNotes
            displayed.highlightTranslations = generated.highlightTranslations
            return displayed
        }
    }

    private func accepts(_ cue: Cue) -> Bool {
        guard let baseline = baselineByIndex[cue.index] else { return false }
        return !cue.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cue.text == baseline.text
            && abs(cue.time - baseline.time) <= 0.001
            && abs(cue.endTime - baseline.endTime) <= 0.001
    }
}

enum ManagedAnalysisPollPolicy {
    static func delay(
        status: ManagedAnalysisJobStatus,
        failureCount: Int
    ) -> TimeInterval? {
        if failureCount > 0 {
            let delays: [TimeInterval] = [2, 4, 8, 15]
            return delays[min(failureCount - 1, delays.count - 1)]
        }
        switch status {
        case .running: return 2
        case .queued: return 5
        case .pausedQuota, .completed, .failed, .cancelled: return nil
        }
    }
}

enum ManagedAnalysisConnectionState: Equatable {
    case streaming
    case reconnecting
    case pollingFallback
}

struct ManagedAnalysisQueuePresentation: Equatable {
    let detail: String?
    let accessibilityLabel: String

    static func make(
        status: ManagedAnalysisJobStatus,
        jobsAhead: Int?,
        estimatedStartSeconds: Int?,
        connection: ManagedAnalysisConnectionState
    ) -> ManagedAnalysisQueuePresentation {
        switch connection {
        case .reconnecting:
            return .init(detail: "正在重新连接进度…", accessibilityLabel: "重新连接中")
        case .pollingFallback:
            return .init(
                detail: "实时连接暂不可用，正在轮询恢复",
                accessibilityLabel: "轮询恢复中"
            )
        case .streaming:
            break
        }

        guard status == .queued else {
            return .init(detail: nil, accessibilityLabel: "服务器解析中")
        }
        guard let jobsAhead else {
            return .init(detail: nil, accessibilityLabel: "排队中")
        }
        guard jobsAhead > 0 else {
            return .init(detail: "即将开始解析", accessibilityLabel: "排队中，即将开始解析")
        }

        let prefix = "前面还有 \(jobsAhead) 个任务"
        guard let estimatedStartSeconds else {
            return .init(detail: prefix, accessibilityLabel: "排队中，\(prefix)")
        }
        // A positive server estimate should never become the misleading
        // user-facing value “0 分钟”. Round up because the ETA is advisory.
        let minutes = max(1, Int(ceil(Double(estimatedStartSeconds) / 60)))
        let detail = "\(prefix)，预计约 \(minutes) 分钟开始"
        return .init(detail: detail, accessibilityLabel: "排队中，\(detail)")
    }
}

struct ManagedAnalysisProgressState: Equatable {
    let jobID: String
    var status: ManagedAnalysisJobStatus
    var completedCues: Int
    var totalCues: Int
    var errorCode: ManagedAnalysisFailureCode?

    init(
        jobID: String,
        status: ManagedAnalysisJobStatus,
        completedCues: Int,
        totalCues: Int,
        errorCode: ManagedAnalysisFailureCode?
    ) {
        self.jobID = jobID
        self.status = status
        self.completedCues = completedCues
        self.totalCues = totalCues
        self.errorCode = errorCode
    }

    init(job: ManagedAnalysisJob) {
        jobID = job.jobId
        status = job.status
        completedCues = job.completedCues
        totalCues = job.totalCues
        errorCode = job.errorCode
    }

    var fraction: Double {
        guard totalCues > 0 else { return status == .completed ? 1 : 0 }
        return min(max(Double(completedCues) / Double(totalCues), 0), 1)
    }

    var isPolling: Bool { status == .queued || status == .running }
    var canCancel: Bool { status == .queued || status == .running }
    var canResume: Bool { status == .pausedQuota || status == .failed || status == .cancelled }
    var blocksEditing: Bool { status != .completed }

    var label: String? {
        switch status {
        case .queued: return "等待服务器"
        case .running: return "AI 解析中 · \(completedCues)/\(totalCues)"
        case .pausedQuota: return "仅英文 · 解析已暂停"
        case .failed: return "仅英文 · AI 解析失败"
        case .cancelled:
            return completedCues > 0 ? "部分解析 · 已停止" : "仅英文 · 已停止"
        case .completed: return nil
        }
    }
}
