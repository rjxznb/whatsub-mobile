import XCTest
@testable import whatsub_mobile

final class AnalysisRetryPolicyTests: XCTestCase {
    func testRetriesTransientFailuresAndHonorsRetryAfter() {
        let cases: [Error] = [
            ChatCompletionsClient.LlmError.network("offline"),
            ChatCompletionsClient.LlmError.api(408, "timeout", retryAfterMilliseconds: nil),
            ChatCompletionsClient.LlmError.api(429, "busy", retryAfterMilliseconds: 7_000),
            ChatCompletionsClient.LlmError.api(503, "unavailable", retryAfterMilliseconds: nil),
            AnalysisContentError.incompleteBatch([4, 5]),
        ]
        for error in cases {
            XCTAssertTrue(AnalysisRetryPolicy.decision(for: error, failedAttempt: 1).shouldRetry)
        }
        XCTAssertEqual(
            AnalysisRetryPolicy.decision(for: cases[2], failedAttempt: 1).delayMilliseconds,
            7_000
        )
    }

    func testDoesNotRetryDeterministicFailures() {
        let cases: [Error] = [
            ChatCompletionsClient.LlmError.notConfigured,
            ChatCompletionsClient.LlmError.consentRequired,
            ChatCompletionsClient.LlmError.api(400, "bad request", retryAfterMilliseconds: nil),
            ChatCompletionsClient.LlmError.api(401, "invalid key", retryAfterMilliseconds: nil),
            ChatCompletionsClient.LlmError.api(403, "forbidden", retryAfterMilliseconds: nil),
            ChatCompletionsClient.LlmError.api(404, "model missing", retryAfterMilliseconds: nil),
            ChatCompletionsClient.LlmError.api(429, "insufficient balance", retryAfterMilliseconds: nil),
            AnalysisPausedError(),
            CancellationError(),
        ]
        for error in cases {
            XCTAssertFalse(AnalysisRetryPolicy.decision(for: error, failedAttempt: 1).shouldRetry)
        }
    }

    func testParsesRetryAfterSecondsAndHttpDate() throws {
        let seconds = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "7"]
        ))
        XCTAssertEqual(ChatCompletionsClient.retryAfterMilliseconds(from: seconds), 7_000)

        let now = Date(timeIntervalSince1970: 0)
        let date = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:00:10 GMT"]
        ))
        XCTAssertEqual(
            ChatCompletionsClient.retryAfterMilliseconds(from: date, now: now),
            10_000
        )
    }
}
