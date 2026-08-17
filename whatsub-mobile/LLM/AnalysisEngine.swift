import Foundation

struct AnalysisPausedError: Error {}

struct AnalysisResumeContext {
    let completedBatches: [Int: [Cue]]
    let completedSummary: AnalysisSummary?
    let partialBatch: AnalysisPartialBatch?
    let onCueAccepted: (Int, Int, Cue, Bool) throws -> Void
    let onBatchCompleted: (Int, [Cue]) throws -> Void
    let onSummaryCompleted: (AnalysisSummary) throws -> Void
    let shouldBeginRequest: () -> Bool
}

struct AnalysisEngine {
    typealias StreamProvider = ([ChatMessage]) -> AsyncThrowingStream<String, Error>
    typealias DiagnosticStreamProvider = ([ChatMessage], @escaping (AnalysisStreamStage) -> Void) -> AsyncThrowingStream<String, Error>

    private let streamProvider: DiagnosticStreamProvider

    init(client: ChatCompletionsClient) { streamProvider = client.streamChat(_:onLifecycle:) }
    init(streamProvider: @escaping StreamProvider) {
        self.streamProvider = { messages, _ in streamProvider(messages) }
    }
    init(diagnosticStreamProvider: @escaping DiagnosticStreamProvider) {
        self.streamProvider = diagnosticStreamProvider
    }

    static func batches(_ cues: [Cue], size: Int = 50) -> [[Cue]] {
        stride(from: 0, to: cues.count, by: size).map { Array(cues[$0..<min($0 + size, cues.count)]) }
    }

    // Retained for persisted and managed legacy payload compatibility. The
    // BYOK path below validates compact rows against immutable source cues.
    static func parseCue(_ obj: Any) -> Cue? {
        guard let dict = obj as? [String: Any] else { return nil }
        if dict["keyPhrases"] != nil || (dict["type"] as? String) == "summary" { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Cue.self, from: data)
    }

    static func parseSummary(_ obj: Any, durationSec: Double?, cues: [Cue]) -> AnalysisSummary? {
        guard let dict = obj as? [String: Any], dict["keyPhrases"] != nil,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? VideoLearningParser.parseSummary(data, durationSec: durationSec, cues: cues)
    }

    func analyze(
        _ cues: [Cue], durationSec: Double? = nil,
        onProgress: @escaping (Int, Int) -> Void,
        onDiagnostic: @escaping (AnalysisStreamEvent) -> Void = { _ in }
    ) async throws -> AnalysisJson {
        try await analyze(
            cues, durationSec: durationSec, completedBatches: [:], completedSummary: nil,
            partialBatch: nil, onCueAccepted: { _, _, _, _ in },
            onBatchCompleted: { _, _ in }, onSummaryCompleted: { _ in },
            shouldBeginRequest: { true }, onProgress: onProgress, onDiagnostic: onDiagnostic
        )
    }

    func analyze(
        _ cues: [Cue], durationSec: Double? = nil,
        completedBatches: [Int: [Cue]], completedSummary: AnalysisSummary?,
        partialBatch: AnalysisPartialBatch? = nil,
        onCueAccepted: @escaping (Int, Int, Cue, Bool) throws -> Void = { _, _, _, _ in },
        onBatchCompleted: @escaping (Int, [Cue]) throws -> Void,
        onSummaryCompleted: @escaping (AnalysisSummary) throws -> Void,
        shouldBeginRequest: @escaping () -> Bool,
        onProgress: @escaping (Int, Int) -> Void,
        onDiagnostic: @escaping (AnalysisStreamEvent) -> Void = { _ in }
    ) async throws -> AnalysisJson {
        try Task.checkCancellation()
        let batched = Self.batches(cues)
        let totalCues = cues.count
        var resultsByBatch: [Int: [Cue]] = [:]
        for (index, result) in completedBatches {
            try Self.validateBatch(index: index, result: result, sourceCues: cues)
            resultsByBatch[index] = result
        }
        var completedCount = resultsByBatch.values.reduce(0) { $0 + $1.count }
        onProgress(completedCount + (partialBatch?.entries.count ?? 0), totalCues + 1)

        for (batchIndex, batch) in batched.enumerated() {
            if resultsByBatch[batchIndex] != nil { continue }
            let restored = partialBatch?.batchIndex == batchIndex ? partialBatch : nil
            let result = try await resolveBatch(
                batch, batchIndex: batchIndex, completedBefore: completedCount,
                restored: restored, onCueAccepted: onCueAccepted,
                shouldBeginRequest: shouldBeginRequest, totalCues: totalCues,
                onProgress: onProgress, onDiagnostic: onDiagnostic
            )
            try Task.checkCancellation()
            try onBatchCompleted(batchIndex, result)
            resultsByBatch[batchIndex] = result
            completedCount += result.count
            onDiagnostic(.init(stage: .batchComplete, batch: batchIndex, parsedCues: completedCount))
        }

        var subtitles = batched.indices.flatMap { resultsByBatch[$0] ?? [] }
        for index in subtitles.indices { subtitles[index].index = index }
        var parsedSummary = completedSummary
        if completedSummary == nil, !subtitles.isEmpty {
            try Task.checkCancellation()
            guard shouldBeginRequest() else { throw AnalysisPausedError() }
            do {
                let parser = JsonLineParser()
                let summaryBatch = batched.count
                onDiagnostic(.init(stage: .preparingRequest, batch: summaryBatch, parsedCues: totalCues))
                let stream = streamProvider(try AnalysisPrompts.boundedSummaryMessages(subtitles)) { stage in
                    onDiagnostic(.init(stage: stage, batch: summaryBatch, parsedCues: totalCues))
                }
                for try await chunk in stream {
                    parser.feed(chunk) { object in
                        if let value = Self.parseSummary(object, durationSec: durationSec, cues: subtitles) { parsedSummary = value }
                    }
                }
                parser.flush { object in
                    if let value = Self.parseSummary(object, durationSec: durationSec, cues: subtitles) { parsedSummary = value }
                }
                try Task.checkCancellation()
            } catch is CancellationError { throw CancellationError() }
            catch { /* Summary is fail-open. */ }
            if let parsedSummary { try onSummaryCompleted(parsedSummary) }
        }

        onProgress(totalCues + 1, totalCues + 1)
        let generatedAt = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let summary = parsedSummary ?? AnalysisSummary(keyPhrases: [], learningGuide: nil, contextProfile: nil)
        return AnalysisJson.assembled(
            subtitles: subtitles, keyPhrases: summary.keyPhrases,
            learningGuide: summary.learningGuide.map { LearningGuide(draft: $0, generatedAt: generatedAt) },
            contextProfile: summary.contextProfile
        )
    }

    private func resolveBatch(
        _ batch: [Cue], batchIndex: Int, completedBefore: Int,
        restored: AnalysisPartialBatch?,
        onCueAccepted: (Int, Int, Cue, Bool) throws -> Void,
        shouldBeginRequest: () -> Bool, totalCues: Int,
        onProgress: (Int, Int) -> Void,
        onDiagnostic: @escaping (AnalysisStreamEvent) -> Void
    ) async throws -> [Cue] {
        var resolved: [Int: Cue] = [:]
        var needsRepair = Set<Int>()
        for entry in restored?.entries ?? [] {
            guard batch.indices.contains(entry.cueOffset), entry.cue.index == batch[entry.cueOffset].index else {
                throw AnalysisCheckpointError.corruptCheckpoint
            }
            resolved[entry.cueOffset] = entry.cue
            if entry.needsAnnotationRepair { needsRepair.insert(entry.cueOffset) }
        }
        let budget = CompactHighlightBudget(
            limit: CompactAnalysisCue.capacity(for: batch.count),
            used: resolved.values.filter(\.isKeyPoint).count
        )

        for attempt in 1...AnalysisRetryPolicy.maxAttempts {
            try Task.checkCancellation()
            let unresolvedOffsets = batch.indices.filter { resolved[$0] == nil }
            if unresolvedOffsets.isEmpty { break }
            guard shouldBeginRequest() else { throw AnalysisPausedError() }
            let requestCues = unresolvedOffsets.map { batch[$0] }
            let requested = Dictionary(uniqueKeysWithValues: requestCues.map { ($0.index, $0) })
            let offsetByIndex = Dictionary(uniqueKeysWithValues: unresolvedOffsets.map { (batch[$0].index, $0) })
            var streamError: Error?
            var callbackError: Error?
            let parser = JsonLineParser()
            onDiagnostic(.init(stage: .preparingRequest, batch: batchIndex, parsedCues: completedBefore + resolved.count))
            let messages = AnalysisPrompts.compactCueMessages(
                requestCues,
                maxHighlightedCues: budget.remaining
            )
            do {
                let stream = streamProvider(messages) { stage in
                    onDiagnostic(.init(stage: stage, batch: batchIndex, parsedCues: completedBefore + resolved.count))
                }
                let accept: (Any) -> Void = { object in
                    guard callbackError == nil,
                          let validation = try? CompactAnalysisCue.validate(object, requested: requested),
                          let offset = offsetByIndex[validation.cue.index], resolved[offset] == nil else { return }
                    let accepted = budget.apply(to: validation)
                    do {
                        try onCueAccepted(batchIndex, offset, accepted.cue, accepted.needsAnnotationRepair)
                        resolved[offset] = accepted.cue
                        if accepted.needsAnnotationRepair { needsRepair.insert(offset) }
                        onDiagnostic(.init(stage: .parsing, batch: batchIndex, parsedCues: completedBefore + resolved.count))
                        onProgress(completedBefore + resolved.count, totalCues + 1)
                    } catch { callbackError = error }
                }
                for try await chunk in stream {
                    parser.feed(chunk, handle: accept)
                    if let callbackError { throw callbackError }
                }
                parser.flush(accept)
                if let callbackError { throw callbackError }
            } catch { streamError = error }
            try Task.checkCancellation()

            let remaining = batch.indices.filter { resolved[$0] == nil }.map { batch[$0].index }
            if remaining.isEmpty { break }
            let failure: Error = streamError ?? AnalysisContentError.incompleteBatch(remaining)
            let decision = AnalysisRetryPolicy.decision(for: failure, failedAttempt: attempt)
            guard decision.shouldRetry else { throw failure }
            onDiagnostic(.init(
                stage: .retryBackoff,
                batch: batchIndex,
                parsedCues: completedBefore + resolved.count
            ))
            try await AnalysisRetryPolicy.sleep(milliseconds: decision.delayMilliseconds)
        }

        let missing = batch.indices.filter { resolved[$0] == nil }.map { batch[$0].index }
        guard missing.isEmpty else { throw AnalysisContentError.incompleteBatch(missing) }
        try await repairAnnotations(
            batch, batchIndex: batchIndex, completedBefore: completedBefore,
            resolved: &resolved, needsRepair: &needsRepair, budget: budget,
            onCueAccepted: onCueAccepted, shouldBeginRequest: shouldBeginRequest,
            totalCues: totalCues, onProgress: onProgress, onDiagnostic: onDiagnostic
        )
        return batch.indices.compactMap { resolved[$0] }
    }

    private func repairAnnotations(
        _ batch: [Cue], batchIndex: Int, completedBefore: Int,
        resolved: inout [Int: Cue], needsRepair: inout Set<Int>,
        budget: CompactHighlightBudget,
        onCueAccepted: (Int, Int, Cue, Bool) throws -> Void,
        shouldBeginRequest: () -> Bool, totalCues: Int,
        onProgress: (Int, Int) -> Void,
        onDiagnostic: @escaping (AnalysisStreamEvent) -> Void
    ) async throws {
        var workingResolved = resolved
        var workingNeedsRepair = needsRepair
        defer {
            resolved = workingResolved
            needsRepair = workingNeedsRepair
        }
        let repairOffsets = batch.indices.filter { workingNeedsRepair.contains($0) }
        guard !repairOffsets.isEmpty else { return }
        var repaired = Set<Int>()
        for attempt in 1...AnalysisRetryPolicy.maxAttempts {
            let pending = repairOffsets.filter { !repaired.contains($0) }
            if pending.isEmpty { break }
            try Task.checkCancellation()
            guard shouldBeginRequest() else { throw AnalysisPausedError() }
            let repairCues = pending.compactMap { workingResolved[$0] }
            let sources = Dictionary(uniqueKeysWithValues: pending.map { ($0, batch[$0]) })
            let offsetByIndex = Dictionary(uniqueKeysWithValues: pending.map { (batch[$0].index, $0) })
            var candidates: [Int: CompactCueValidation] = [:]
            var streamError: Error?
            let parser = JsonLineParser()
            onDiagnostic(.init(stage: .preparingRequest, batch: batchIndex, parsedCues: completedBefore + workingResolved.count))
            do {
                let stream = streamProvider(AnalysisPrompts.compactRepairMessages(repairCues, maxHighlightedCues: budget.remaining)) { stage in
                    onDiagnostic(.init(stage: stage, batch: batchIndex, parsedCues: completedBefore + workingResolved.count))
                }
                let parse: (Any) -> Void = { object in
                    guard var dict = object as? [String: Any],
                          let index = Self.compactIndex(dict["i"] ?? dict["index"]),
                          let offset = offsetByIndex[index], candidates[offset] == nil,
                          let current = workingResolved[offset], let source = sources[offset] else { return }
                    dict["zh"] = current.translation
                    if let validation = try? CompactAnalysisCue.validate(dict, requested: [index: source]),
                       !validation.needsAnnotationRepair {
                        candidates[offset] = validation
                    }
                }
                for try await chunk in stream { parser.feed(chunk, handle: parse) }
                parser.flush(parse)
            } catch { streamError = error }
            try Task.checkCancellation()

            for offset in pending {
                guard let validation = candidates[offset], let current = workingResolved[offset] else { continue }
                let budgeted = budget.apply(to: validation)
                let accepted = budgeted.cue.isKeyPoint ? budgeted.cue : current
                try onCueAccepted(batchIndex, offset, accepted, false)
                workingResolved[offset] = accepted
                workingNeedsRepair.remove(offset)
                repaired.insert(offset)
                onProgress(completedBefore + workingResolved.count, totalCues + 1)
            }
            if repaired.count == repairOffsets.count { break }
            let pendingIndexes = pending
                .filter { !repaired.contains($0) }
                .map { batch[$0].index }
            let failure: Error = streamError ?? AnalysisContentError.incompleteBatch(pendingIndexes)
            let decision = AnalysisRetryPolicy.decision(for: failure, failedAttempt: attempt)
            if decision.shouldRetry {
                onDiagnostic(.init(
                    stage: .retryBackoff,
                    batch: batchIndex,
                    parsedCues: completedBefore + workingResolved.count
                ))
                try await AnalysisRetryPolicy.sleep(milliseconds: decision.delayMilliseconds)
                continue
            }
            break
        }

        // Annotation repair is fail-open: persist translation-only entries and
        // complete the durable batch instead of regenerating translations.
        for offset in repairOffsets where !repaired.contains(offset) {
            guard var cue = workingResolved[offset] else { continue }
            cue.isKeyPoint = false
            cue.highlightWords = []
            cue.keyNotes = [:]
            cue.highlightTranslations = [:]
            try onCueAccepted(batchIndex, offset, cue, false)
            workingResolved[offset] = cue
            workingNeedsRepair.remove(offset)
        }
    }

    private static func compactIndex(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func validateBatch(index: Int, result: [Cue], sourceCues: [Cue]) throws {
        var checkpoint = AnalysisCheckpoint(fingerprint: "validation")
        try checkpoint.recordBatch(index: index, result: result, sourceCues: sourceCues)
    }
}
