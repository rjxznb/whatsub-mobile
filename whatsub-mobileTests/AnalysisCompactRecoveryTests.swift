import XCTest
@testable import whatsub_mobile

final class AnalysisCompactRecoveryTests: XCTestCase {
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [Result<String, Error>]
        private(set) var prompts: [String] = []

        init(_ responses: [Result<String, Error>]) { self.responses = responses }

        func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            prompts.append(messages.map(\.content).joined(separator: "\n"))
            let response = responses.isEmpty
                ? .success("")
                : responses.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                switch response {
                case .success(let text):
                    continuation.yield(text)
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func cues(_ count: Int) -> [Cue] {
        (0..<count).map { Cue(index: $0, time: Double($0), endTime: Double($0 + 1), text: "source \($0)") }
    }

    private func lines(_ cues: ArraySlice<Cue>) -> String {
        cues.map { "{\"i\":\($0.index),\"zh\":\"译文 \($0.index)\",\"p\":[]}" }.joined(separator: "\n")
    }

    func testContinuesOnlyTheEightMissingCueIndexes() async throws {
        let source = cues(50)
        let script = Script([
            .success(lines(source[0..<42])),
            .success(lines(source[42..<50])),
        ])
        let engine = AnalysisEngine(streamProvider: script.stream)
        var accepted: [Int] = []
        var completed: [Cue] = []
        let completedSummary = AnalysisSummary(keyPhrases: [], learningGuide: nil, contextProfile: nil)

        _ = try await engine.analyze(
            source,
            completedBatches: [:],
            completedSummary: completedSummary,
            onCueAccepted: { _, offset, _, _ in accepted.append(offset) },
            onBatchCompleted: { _, cues in completed = cues },
            onSummaryCompleted: { _ in },
            shouldBeginRequest: { true },
            onProgress: { _, _ in }
        )

        XCTAssertEqual(accepted, Array(0..<50))
        XCTAssertEqual(completed.count, 50)
        XCTAssertEqual(script.prompts.count, 2)
        XCTAssertFalse(script.prompts[1].contains("0\t\"source 0\""))
        XCTAssertTrue(script.prompts[1].contains("42\t\"source 42\""))
        XCTAssertTrue(script.prompts[1].contains("49\t\"source 49\""))
    }

    func testPermanentAuthenticationFailureDoesNotRetry() async {
        let script = Script([
            .failure(ChatCompletionsClient.LlmError.api(
                401,
                "invalid key",
                retryAfterMilliseconds: nil
            )),
        ])
        let engine = AnalysisEngine(streamProvider: script.stream)

        do {
            _ = try await engine.analyze(cues(1), onProgress: { _, _ in })
            XCTFail("401 must fail")
        } catch {
            XCTAssertEqual(script.prompts.count, 1)
        }
    }

    func testRetryBackoffIsReportedBeforeAContinuationRequest() async throws {
        let source = cues(1)
        let script = Script([
            .success(""),
            .success(lines(source[0..<1])),
        ])
        let engine = AnalysisEngine(streamProvider: script.stream)
        let completedSummary = AnalysisSummary(keyPhrases: [], learningGuide: nil, contextProfile: nil)
        var stages: [AnalysisStreamStage] = []

        _ = try await engine.analyze(
            source,
            completedBatches: [:],
            completedSummary: completedSummary,
            onBatchCompleted: { _, _ in },
            onSummaryCompleted: { _ in },
            shouldBeginRequest: { true },
            onProgress: { _, _ in },
            onDiagnostic: { stages.append($0.stage) }
        )

        XCTAssertTrue(stages.contains(.retryBackoff))
        XCTAssertEqual(script.prompts.count, 2)
    }
}
