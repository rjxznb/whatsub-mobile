import Foundation

struct AnalysisPausedError: Error {}

struct AnalysisResumeContext {
    let completedBatches: [Int: [Cue]]
    let completedSummary: AnalysisSummary?
    let onBatchCompleted: (Int, [Cue]) throws -> Void
    let onSummaryCompleted: (AnalysisSummary) throws -> Void
    let shouldBeginRequest: () -> Bool
}

/// Two-phase subtitle analysis: streamed 50-cue batches followed by one
/// streamed summary request. Complete batches can be supplied and persisted,
/// allowing BYOK work to resume without paying for successful requests twice.
struct AnalysisEngine {
    typealias StreamProvider = ([ChatMessage]) -> AsyncThrowingStream<String, Error>
    typealias DiagnosticStreamProvider = (
        [ChatMessage],
        @escaping (AnalysisStreamStage) -> Void
    ) -> AsyncThrowingStream<String, Error>

    private let streamProvider: DiagnosticStreamProvider

    init(client: ChatCompletionsClient) {
        streamProvider = client.streamChat(_:onLifecycle:)
    }

    init(streamProvider: @escaping StreamProvider) {
        self.streamProvider = { messages, _ in streamProvider(messages) }
    }

    init(diagnosticStreamProvider: @escaping DiagnosticStreamProvider) {
        self.streamProvider = diagnosticStreamProvider
    }

    static func batches(_ cues: [Cue], size: Int = 50) -> [[Cue]] {
        stride(from: 0, to: cues.count, by: size).map {
            Array(cues[$0..<min($0 + size, cues.count)])
        }
    }

    static func parseCue(_ obj: Any) -> Cue? {
        guard let dict = obj as? [String: Any] else { return nil }
        if dict["keyPhrases"] != nil || (dict["type"] as? String) == "summary" {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Cue.self, from: data)
    }

    static func parseSummary(
        _ obj: Any,
        durationSec: Double?,
        cues: [Cue]
    ) -> AnalysisSummary? {
        guard let dict = obj as? [String: Any],
              dict["keyPhrases"] != nil,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? VideoLearningParser.parseSummary(
            data,
            durationSec: durationSec,
            cues: cues
        )
    }

    func analyze(
        _ cues: [Cue],
        durationSec: Double? = nil,
        onProgress: @escaping (Int, Int) -> Void,
        onDiagnostic: @escaping (AnalysisStreamEvent) -> Void = { _ in }
    ) async throws -> AnalysisJson {
        try await analyze(
            cues,
            durationSec: durationSec,
            completedBatches: [:],
            completedSummary: nil,
            onBatchCompleted: { _, _ in },
            onSummaryCompleted: { _ in },
            shouldBeginRequest: { true },
            onProgress: onProgress,
            onDiagnostic: onDiagnostic
        )
    }

    /// Calls each checkpoint callback synchronously before considering the next
    /// request. Returning false from `shouldBeginRequest` pauses only at a safe
    /// request boundary; an already-open stream is allowed to finish and persist.
    func analyze(
        _ cues: [Cue],
        durationSec: Double? = nil,
        completedBatches: [Int: [Cue]],
        completedSummary: AnalysisSummary?,
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
        onProgress(resultsByBatch.values.reduce(0) { $0 + $1.count }, totalCues + 1)

        for (batchIndex, batch) in batched.enumerated() {
            if resultsByBatch[batchIndex] != nil { continue }
            try Task.checkCancellation()
            guard shouldBeginRequest() else { throw AnalysisPausedError() }

            let completedBefore = resultsByBatch.values.reduce(0) { $0 + $1.count }
            var batchResult: [Cue] = []
            let parser = JsonLineParser()
            onDiagnostic(AnalysisStreamEvent(
                stage: .preparingRequest, batch: batchIndex, parsedCues: completedBefore
            ))
            let stream = streamProvider([
                ChatMessage(role: "system", content: AnalysisPrompts.system),
                ChatMessage(role: "user", content: AnalysisPrompts.userPrompt(batch)),
            ]) { stage in
                onDiagnostic(AnalysisStreamEvent(
                    stage: stage, batch: batchIndex, parsedCues: completedBefore + batchResult.count
                ))
            }
            for try await chunk in stream {
                parser.feed(chunk) { object in
                    if let cue = Self.parseCue(object) {
                        batchResult.append(cue)
                        onDiagnostic(AnalysisStreamEvent(
                            stage: .parsing,
                            batch: batchIndex,
                            parsedCues: completedBefore + batchResult.count
                        ))
                        onProgress(completedBefore + batchResult.count, totalCues + 1)
                    }
                }
            }
            parser.flush { object in
                if let cue = Self.parseCue(object) {
                    batchResult.append(cue)
                    onDiagnostic(AnalysisStreamEvent(
                        stage: .parsing,
                        batch: batchIndex,
                        parsedCues: completedBefore + batchResult.count
                    ))
                    onProgress(completedBefore + batchResult.count, totalCues + 1)
                }
            }

            try Self.validateBatch(index: batchIndex, result: batchResult, sourceCues: cues)
            try onBatchCompleted(batchIndex, batchResult)
            resultsByBatch[batchIndex] = batchResult
            onDiagnostic(AnalysisStreamEvent(
                stage: .batchComplete,
                batch: batchIndex,
                parsedCues: completedBefore + batchResult.count
            ))
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
                onDiagnostic(AnalysisStreamEvent(
                    stage: .preparingRequest, batch: summaryBatch, parsedCues: totalCues
                ))
                let messages = try AnalysisPrompts.boundedSummaryMessages(subtitles)
                let stream = streamProvider(messages) { stage in
                    onDiagnostic(AnalysisStreamEvent(
                        stage: stage, batch: summaryBatch, parsedCues: totalCues
                    ))
                }
                for try await chunk in stream {
                    parser.feed(chunk) { object in
                        if let parsed = Self.parseSummary(
                            object,
                            durationSec: durationSec,
                            cues: subtitles
                        ) {
                            parsedSummary = parsed
                        }
                    }
                }
                parser.flush { object in
                    if let parsed = Self.parseSummary(
                        object,
                        durationSec: durationSec,
                        cues: subtitles
                    ) {
                        parsedSummary = parsed
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Cue analysis remains useful even if the optional summary fails.
            }
            if let parsedSummary {
                try onSummaryCompleted(parsedSummary)
            }
        }

        onProgress(totalCues + 1, totalCues + 1)
        let generatedAt = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let summary = parsedSummary ?? AnalysisSummary(
            keyPhrases: [], learningGuide: nil, contextProfile: nil
        )
        return AnalysisJson.assembled(
            subtitles: subtitles,
            keyPhrases: summary.keyPhrases,
            learningGuide: summary.learningGuide.map {
                LearningGuide(draft: $0, generatedAt: generatedAt)
            },
            contextProfile: summary.contextProfile
        )
    }

    private static func validateBatch(index: Int, result: [Cue], sourceCues: [Cue]) throws {
        var checkpoint = AnalysisCheckpoint(fingerprint: "validation")
        try checkpoint.recordBatch(index: index, result: result, sourceCues: sourceCues)
    }
}
