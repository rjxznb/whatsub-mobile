import Foundation

/// Merges only server-generated fields over an immutable English transcript.
/// Text, timing, ordering, and cue identity always remain client/server
/// caption-source authority rather than model authority.
struct ProgressiveAnalysisOverlay {
    private let baselineByIndex: [Int: Cue]
    private(set) var generatedByIndex: [Int: Cue] = [:]

    init(baseline: [Cue]) {
        baselineByIndex = Dictionary(uniqueKeysWithValues: baseline.map { ($0.index, $0) })
    }

    var resolvedIndexes: Set<Int> { Set(generatedByIndex.keys) }

    mutating func merge(_ batches: [ManagedAnalysisCompletedBatch]) {
        for cue in batches.flatMap(\.subtitles) where generatedByIndex[cue.index] == nil {
            guard let baseline = baselineByIndex[cue.index],
                  !cue.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  cue.text == baseline.text,
                  abs(cue.time - baseline.time) <= 0.001,
                  abs(cue.endTime - baseline.endTime) <= 0.001 else { continue }
            generatedByIndex[cue.index] = cue
        }
    }

    func displayedCues(from baseline: [Cue]) -> [Cue] {
        baseline.map { source in
            guard let generated = generatedByIndex[source.index] else { return source }
            var displayed = source
            displayed.translation = generated.translation
            displayed.isKeyPoint = generated.isKeyPoint
            displayed.highlightWords = generated.highlightWords
            displayed.keyNotes = generated.keyNotes
            displayed.highlightTranslations = generated.highlightTranslations
            return displayed
        }
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
    var canResume: Bool { status == .pausedQuota || status == .failed || status == .cancelled }
    var blocksEditing: Bool { status != .completed }

    var label: String? {
        switch status {
        case .queued: return "等待服务器"
        case .running: return "AI 解析中 · \(completedCues)/\(totalCues)"
        case .pausedQuota: return "仅英文 · 解析已暂停"
        case .failed: return "仅英文 · AI 解析失败"
        case .cancelled: return "仅英文 · 已取消"
        case .completed: return nil
        }
    }
}
