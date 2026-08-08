import Foundation

struct AnalysisPausedError: Error {}

struct AnalysisResumeContext {
    let completedBatches: [Int: [Cue]]
    let completedSummary: [KeyPhrase]?
    let onBatchCompleted: (Int, [Cue]) throws -> Void
    let onSummaryCompleted: ([KeyPhrase]) throws -> Void
    let shouldBeginRequest: () -> Bool
}

/// Two-phase subtitle analysis: streamed 50-cue batches followed by one
/// streamed summary request. Complete batches can be supplied and persisted,
/// allowing BYOK work to resume without paying for successful requests twice.
struct AnalysisEngine {
    typealias StreamProvider = ([ChatMessage]) -> AsyncThrowingStream<String, Error>

    private let streamProvider: StreamProvider

    init(client: ChatCompletionsClient) {
        streamProvider = client.streamChat
    }

    init(streamProvider: @escaping StreamProvider) {
        self.streamProvider = streamProvider
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

    static func parseSummary(_ obj: Any) -> [KeyPhrase]? {
        guard let dict = obj as? [String: Any],
              dict["keyPhrases"] != nil,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        struct Summary: Decodable { let keyPhrases: [KeyPhrase] }
        return (try? JSONDecoder().decode(Summary.self, from: data))?.keyPhrases
    }

    func analyze(
        _ cues: [Cue],
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> AnalysisJson {
        try await analyze(
            cues,
            completedBatches: [:],
            completedSummary: nil,
            onBatchCompleted: { _, _ in },
            onSummaryCompleted: { _ in },
            shouldBeginRequest: { true },
            onProgress: onProgress
        )
    }

    /// Calls each checkpoint callback synchronously before considering the next
    /// request. Returning false from `shouldBeginRequest` pauses only at a safe
    /// request boundary; an already-open stream is allowed to finish and persist.
    func analyze(
        _ cues: [Cue],
        completedBatches: [Int: [Cue]],
        completedSummary: [KeyPhrase]?,
        onBatchCompleted: @escaping (Int, [Cue]) throws -> Void,
        onSummaryCompleted: @escaping ([KeyPhrase]) throws -> Void,
        shouldBeginRequest: @escaping () -> Bool,
        onProgress: @escaping (Int, Int) -> Void
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
            let stream = streamProvider([
                ChatMessage(role: "system", content: AnalysisPrompts.system),
                ChatMessage(role: "user", content: AnalysisPrompts.userPrompt(batch)),
            ])
            for try await chunk in stream {
                parser.feed(chunk) { object in
                    if let cue = Self.parseCue(object) {
                        batchResult.append(cue)
                        onProgress(completedBefore + batchResult.count, totalCues + 1)
                    }
                }
            }
            parser.flush { object in
                if let cue = Self.parseCue(object) {
                    batchResult.append(cue)
                    onProgress(completedBefore + batchResult.count, totalCues + 1)
                }
            }

            try Self.validateBatch(index: batchIndex, result: batchResult, sourceCues: cues)
            try onBatchCompleted(batchIndex, batchResult)
            resultsByBatch[batchIndex] = batchResult
        }

        var subtitles = batched.indices.flatMap { resultsByBatch[$0] ?? [] }
        for index in subtitles.indices { subtitles[index].index = index }

        var keyPhrases = completedSummary ?? []
        if completedSummary == nil, !subtitles.isEmpty {
            try Task.checkCancellation()
            guard shouldBeginRequest() else { throw AnalysisPausedError() }
            do {
                let parser = JsonLineParser()
                let stream = streamProvider([
                    ChatMessage(role: "system", content: AnalysisPrompts.system),
                    ChatMessage(role: "user", content: AnalysisPrompts.summaryPrompt(subtitles)),
                ])
                for try await chunk in stream {
                    parser.feed(chunk) { object in
                        if let summary = Self.parseSummary(object) { keyPhrases = summary }
                    }
                }
                parser.flush { object in
                    if let summary = Self.parseSummary(object) { keyPhrases = summary }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Cue analysis remains useful even if the optional summary fails.
                keyPhrases = []
            }
            try onSummaryCompleted(keyPhrases)
        }

        onProgress(totalCues + 1, totalCues + 1)
        return AnalysisJson.assembled(subtitles: subtitles, keyPhrases: keyPhrases)
    }

    private static func validateBatch(index: Int, result: [Cue], sourceCues: [Cue]) throws {
        var checkpoint = AnalysisCheckpoint(fingerprint: "validation")
        try checkpoint.recordBatch(index: index, result: result, sourceCues: sourceCues)
    }
}
