import Foundation

/// A user-facing failure carrying both a friendly Chinese message AND a
/// `kind` that tells the UI which call-to-action button to render alongside.
///
/// Why a separate type instead of using `Error` / `LocalizedError` directly:
/// our outcome enums (`AnalysisOutcome`, `GradingOutcome`, …) historically
/// used `case failure(String)` because Swift's `Result<S, F>` requires
/// `F: Error` — see `feedback_swift_result_string_compile`. We kept the
/// custom enum pattern but upgraded the failure payload from a bare String
/// to this struct so views can tell apart "the server returned an error
/// you can pay your way out of" (subscribe CTA) from "AI 还没配置好"
/// (settings CTA) from generic transport noise.
///
/// `from(_:)` is the single funnel: every catch-site converts whatever
/// `Error` it caught into a `RemoteFailure`, so any code that needs to
/// surface an error in the UI calls this once and forgets about the
/// underlying error taxonomy.
struct RemoteFailure: Equatable {
    let message: String
    let kind: Kind

        enum Kind: Equatable {
        /// Plain failure — render text only.
        case generic
        /// Subscribe-to-fix — the backend told us the user's tier doesn't
        /// include this feature OR they've hit a quota that Pro lifts.
        /// UI should show a 「订阅 Pro」 button that opens `SubscribeSheet`.
        case subscribeUpsell
        /// Configure-LLM — user hasn't set up an API key AND isn't on a
        /// managed-relay tier that would cover for them. UI should
        /// deep-link to 「我的 → LLM 设置」.
        case configureLLM
        /// Global AI-feature consent hasn't been granted yet (App Store
        /// Guideline 5.1.1(i) / 5.1.2(i), 2026-06-09). UI should re-present
        /// the `AIConsentGate` sheet so the user can accept and retry.
            case consentRequired
            /// The account cannot use the persisted BYOK configuration. The
            /// UI should refresh `/me` and present the entitled mode only.
            case byokNotEntitled
    }

    init(message: String, kind: Kind = .generic) {
        self.message = message
        self.kind = kind
    }

    /// Funnel for converting any caught Swift `Error` into a `RemoteFailure`.
    /// Recognises `ChatCompletionsClient.LlmError` (the LLM throw site) and
    /// `APIError` (the REST throw site) and maps known sub-cases to the
    /// right `kind` so the UI shows the appropriate CTA. Anything unknown
    /// falls through to `.generic` with the standard `localizedDescription`.
    static func from(_ error: Error, fallback: String = "出错了，稍后再试一次") -> RemoteFailure {
        if let entitlement = error as? LlmEntitlementError {
            switch entitlement {
            case .byokNotEntitled:
                return RemoteFailure(
                    message: entitlement.errorDescription ?? "当前账号不能使用自己的 API Key",
                    kind: .byokNotEntitled,
                )
            case .managedRelayNotEntitled:
                return RemoteFailure(
                    message: entitlement.errorDescription ?? "当前账号不能使用 whatSub 托管 AI",
                    kind: .subscribeUpsell,
                )
            }
        }
        if let llm = error as? ChatCompletionsClient.LlmError {
            switch llm {
            case .policy(let code, let message, _):
                switch code {
                // license_blocked / free_used_up / trial_used_up / quota_exceeded
                // all share the same fix: pay for Pro. Bundle them into one
                // `.subscribeUpsell` so the CTA logic is one branch.
                case .licenseBlocked, .freeUsedUp, .trialUsedUp, .quotaExceeded:
                    return RemoteFailure(message: message, kind: .subscribeUpsell)
                }
            case .notConfigured:
                if LlmEntitlementCache.current(for: KeychainStore.load()?.email)?.byok == true {
                    return RemoteFailure(
                        message: llm.errorDescription ?? "请先在「我的 → LLM 设置」填好 API Key",
                        kind: .configureLLM
                    )
                }
                return RemoteFailure(
                    message: "托管 AI 暂时无法连接，请检查登录状态和网络后重试。",
                    kind: .generic
                )
            case .consentRequired:
                return RemoteFailure(
                    message: llm.errorDescription ?? "请先同意 AI 功能的数据使用说明",
                    kind: .consentRequired,
                )
            case .network, .api, .badResponse:
                return RemoteFailure(message: llm.errorDescription ?? fallback,
                                     kind: .generic)
            }
        }
        if let api = error as? APIError {
            return RemoteFailure(message: api.chinese, kind: .generic)
        }
        if let local = error as? LocalizedError, let desc = local.errorDescription {
            return RemoteFailure(message: desc, kind: .generic)
        }
        return RemoteFailure(message: "\(fallback)：\(error.localizedDescription)",
                             kind: .generic)
    }

    /// Convenience for "I already have a friendly string, just wrap it" —
    /// callers that compose their own message (e.g., "OCR 文本为空,先拍一张…")
    /// without going through the error taxonomy.
    static func message(_ text: String) -> RemoteFailure {
        RemoteFailure(message: text, kind: .generic)
    }
}
