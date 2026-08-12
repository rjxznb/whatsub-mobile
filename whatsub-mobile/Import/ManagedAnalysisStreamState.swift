import Foundation

struct ManagedAnalysisPreviewKey: Hashable {
    let batchIndex: Int
    let attempt: Int
    let cueIndex: Int
}

/// Pure recovery reducer for the replayable mobile-analysis event protocol.
/// Durable result pages and in-flight previews deliberately remain distinct:
/// a preview is useful for immediate rendering, but only `/results` is durable.
struct ManagedAnalysisStreamState {
    private(set) var lastEventID: Int64?
    private(set) var previews: [ManagedAnalysisPreviewKey: ManagedAnalysisStreamCue] = [:]
    private(set) var currentAttemptByBatch: [Int: Int] = [:]
    private(set) var status: ManagedAnalysisJobStatus?
    private(set) var totalCues = 0
    private(set) var completedCues = 0
    private(set) var completedBatchCursor = -1
    private(set) var errorCode: ManagedAnalysisFailureCode?
    private(set) var jobsAhead: Int?
    private(set) var estimatedStartSeconds: Int?
    private(set) var needsDurableResync = false

    mutating func apply(_ event: ManagedAnalysisStreamEvent) {
        switch event {
        case .connected:
            return
        case let .snapshot(snapshot):
            applySnapshot(snapshot)
            return
        case .resync:
            resetForResync()
            return
        case let .cue(event):
            guard shouldApply(event.eventId) else { return }
            applyCue(event)
            lastEventID = event.eventId
        case let .batchReset(event):
            guard shouldApply(event.eventId) else { return }
            applyReset(event)
            lastEventID = event.eventId
        case let .batchCommitted(event):
            guard shouldApply(event.eventId) else { return }
            completedCues = max(completedCues, event.completedCues)
            lastEventID = event.eventId
        case let .phase(event):
            guard shouldApply(event.eventId) else { return }
            lastEventID = event.eventId
        case let .jobState(event):
            guard shouldApply(event.eventId) else { return }
            status = event.status
            errorCode = event.errorCode.flatMap(ManagedAnalysisFailureCode.init(rawValue:))
            if event.status != .queued {
                jobsAhead = nil
                estimatedStartSeconds = nil
            }
            lastEventID = event.eventId
        }
    }

    mutating func applyDurable(_ results: ManagedAnalysisResultsPage) {
        status = results.status
        totalCues = results.totalCues
        completedCues = results.completedCues
        completedBatchCursor = max(completedBatchCursor, results.nextBatchCursor)
        errorCode = results.errorCode
        needsDurableResync = false

        let committed = Set(results.batches.map(\.batchIndex))
        guard !committed.isEmpty else { return }
        previews = previews.filter { !committed.contains($0.key.batchIndex) }
        for batchIndex in committed {
            currentAttemptByBatch.removeValue(forKey: batchIndex)
        }
    }

    mutating func resetForColdSnapshot() {
        lastEventID = nil
        previews.removeAll()
        currentAttemptByBatch.removeAll()
        jobsAhead = nil
        estimatedStartSeconds = nil
        needsDurableResync = false
    }

    private mutating func applySnapshot(_ snapshot: ManagedAnalysisStreamSnapshot) {
        lastEventID = snapshot.latestEventId
        status = snapshot.status
        totalCues = snapshot.totalCues
        completedCues = snapshot.completedCues
        completedBatchCursor = snapshot.completedBatchCursor
        errorCode = snapshot.errorCode.flatMap(ManagedAnalysisFailureCode.init(rawValue:))
        jobsAhead = snapshot.status == .queued ? snapshot.jobsAhead : nil
        estimatedStartSeconds = snapshot.status == .queued ? snapshot.estimatedStartSeconds : nil
        previews.removeAll()
        currentAttemptByBatch.removeAll()
        needsDurableResync = false

        guard let current = snapshot.currentAttempt else { return }
        currentAttemptByBatch[current.batchIndex] = current.attempt
        for event in current.cues {
            guard event.batchIndex == current.batchIndex,
                  event.attempt == current.attempt,
                  event.cueIndex == event.cue.index else { continue }
            previews[.init(
                batchIndex: current.batchIndex,
                attempt: current.attempt,
                cueIndex: event.cue.index
            )] = event.cue
        }
    }

    private mutating func resetForResync() {
        lastEventID = nil
        previews.removeAll()
        currentAttemptByBatch.removeAll()
        needsDurableResync = true
    }

    private func shouldApply(_ eventID: Int64) -> Bool {
        guard let lastEventID else { return true }
        return eventID > lastEventID
    }

    private mutating func applyCue(_ event: ManagedAnalysisCueStreamEvent) {
        guard let batchIndex = event.batchIndex,
              let attempt = event.attempt,
              event.cueIndex == event.cue.index else { return }

        if let currentAttempt = currentAttemptByBatch[batchIndex] {
            guard attempt >= currentAttempt else { return }
            if attempt > currentAttempt {
                removePreviews(batchIndex: batchIndex, attempt: currentAttempt)
                currentAttemptByBatch[batchIndex] = attempt
            }
        } else {
            currentAttemptByBatch[batchIndex] = attempt
        }

        previews[.init(
            batchIndex: batchIndex,
            attempt: attempt,
            cueIndex: event.cue.index
        )] = event.cue
    }

    private mutating func applyReset(_ event: ManagedAnalysisBatchResetStreamEvent) {
        guard let batchIndex = event.batchIndex else { return }
        removePreviews(batchIndex: batchIndex, attempt: event.abandonedAttempt)

        let current = currentAttemptByBatch[batchIndex]
        if current == nil || current == event.abandonedAttempt {
            if let nextAttempt = event.nextAttempt {
                currentAttemptByBatch[batchIndex] = nextAttempt
            } else {
                currentAttemptByBatch.removeValue(forKey: batchIndex)
            }
        }
    }

    private mutating func removePreviews(batchIndex: Int, attempt: Int) {
        previews = previews.filter {
            $0.key.batchIndex != batchIndex || $0.key.attempt != attempt
        }
    }
}
