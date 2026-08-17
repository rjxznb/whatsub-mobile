import Foundation

enum AnalysisContentError: LocalizedError {
    case incompleteBatch([Int])
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .incompleteBatch(let indexes):
            return "AI 返回格式不完整，仍有 \(indexes.count) 条字幕未完成。"
        case .emptyResponse:
            return "AI 没有返回可解析的字幕内容。"
        }
    }
}

struct AnalysisRetryDecision {
    let shouldRetry: Bool
    let delayMilliseconds: Int
}

enum AnalysisRetryPolicy {
    static let maxAttempts = 4
    private static let backoffs = [500, 1_500, 3_500]

    static func decision(for error: Error, failedAttempt: Int) -> AnalysisRetryDecision {
        guard failedAttempt < maxAttempts else {
            return AnalysisRetryDecision(shouldRetry: false, delayMilliseconds: 0)
        }
        let base = backoffs.indices.contains(failedAttempt - 1)
            ? backoffs[failedAttempt - 1]
            : backoffs.last ?? 0
        let retryAfter: Int
        let retryable: Bool

        switch error {
        case is CancellationError, is AnalysisPausedError:
            retryable = false
            retryAfter = 0
        case let llm as ChatCompletionsClient.LlmError:
            switch llm {
            case .notConfigured, .consentRequired, .policy, .badResponse:
                retryable = false
                retryAfter = 0
            case .network:
                retryable = true
                retryAfter = 0
            case let .api(status, detail, providerDelay):
                let normalized = detail.lowercased()
                let quotaFailure = normalized.contains("quota")
                    || normalized.contains("balance")
                    || normalized.contains("insufficient")
                    || normalized.contains("余额")
                    || normalized.contains("额度")
                retryable = !quotaFailure
                    && (status == 0 || status == 408 || status == 429 || status >= 500)
                retryAfter = providerDelay ?? 0
            }
        case is AnalysisContentError:
            retryable = true
            retryAfter = 0
        default:
            retryable = error is URLError
            retryAfter = 0
        }
        return AnalysisRetryDecision(
            shouldRetry: retryable,
            delayMilliseconds: retryable ? max(base, retryAfter) : 0
        )
    }

    static func sleep(milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}
