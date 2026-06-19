import Foundation

struct ChatMessage { let role: String; let content: String }

/// Minimal /chat/completions client. The non-streaming `chat(_:)` is used by
/// import + CollectSheet (one shot, return the full content). The streaming
/// `stream(_:)` is used by QuickChat for low-latency turn-by-turn dialogue
/// (TTS starts on the first chunk).
///
/// `session` is injectable so tests can stub the URLProtocol.
struct ChatCompletionsClient {
    let settings: LlmSettings
    let session: URLSession
    /// Optional explicit Bearer override — used by tests + special-case
    /// callers (e.g. relay LLM quota check). Production code leaves this
    /// nil and the resolver reads the session token from Keychain.
    let sessionTokenOverride: String?

    init(settings: LlmSettings, session: URLSession = .shared,
         sessionTokenOverride: String? = nil) {
        self.settings = settings
        self.session = session
        self.sessionTokenOverride = sessionTokenOverride
    }

    /// Effective wire config for one call — collapses the "use relay vs
    /// BYOK" decision into one place so the request builder doesn't have
    /// to branch repeatedly. When relay mode is on AND we have a session
    /// token, we hit the whatsub-hosted proxy with the user's bearer.
    /// Otherwise fall back to the user's BYOK config.
    private struct Resolved {
        let baseUrl: String
        let bearer: String
        let model: String
        /// Relay forces `stream: true` server-side and returns SSE, so we
        /// must parse the SSE here. BYOK keeps the simpler JSON path.
        let usesRelaySSE: Bool
    }

    private func resolveConfig() -> Resolved? {
        if settings.useManagedRelay {
            let token = sessionTokenOverride ?? KeychainStore.load()?.sessionToken ?? ""
            if !token.isEmpty {
                return Resolved(
                    baseUrl: Endpoints.llmRelayClientBase,
                    bearer: token,
                    model: settings.model,        // ignored server-side; sent for completeness
                    usesRelaySSE: true,
                )
            }
            // Relay on but no token (not logged in / token expired) — fall
            // through to BYOK if it's configured, else treat as not-configured.
        }
        guard !settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return Resolved(
            baseUrl: settings.baseUrl,
            bearer: settings.apiKey,
            model: settings.model,
            usesRelaySSE: false,
        )
    }

    // MARK: - non-streaming (unchanged caller surface)

    func chat(_ messages: [ChatMessage]) async throws -> String {
        // Defense-in-depth gate for App Store Guideline 5.1.1(i) / 5.1.2(i):
        // even if the root-level AIConsentGate never presented for some reason,
        // every AI call short-circuits here until the user has acknowledged
        // the data-sharing disclosure. The error is mapped to a friendly
        // RemoteFailure.Kind.consentRequired so the UI can re-present the gate.
        guard AIConsentStore.hasAcceptedRaw else { throw LlmError.consentRequired }
        guard let r = resolveConfig() else { throw LlmError.notConfigured }
        guard let url = URL(string: "\(r.baseUrl)/chat/completions") else {
            throw LlmError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(r.bearer)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120

        var body: [String: Any] = [
            "model": r.model,
            "temperature": 0.3,
            // Set explicitly — DeepSeek v4 reasoning models can otherwise burn
            // the implicit token budget on internal reasoning and emit empty
            // `content`. 4096 covers our longest expected dialog+verdict turn.
            "max_tokens": 4096,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if r.usesRelaySSE {
            // Relay forces stream:true server-side so the wire is always
            // SSE — be explicit on our end so future relay tightening
            // (e.g. rejecting stream:false) can't surprise us.
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        } else {
            body["stream"] = false
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch {
            // Surface the URLError code + URL so the diagnostic tells us which
            // failure mode hit (timeout vs DNS vs TLS vs offline) without the
            // engineer needing to re-bind a debugger. The user-facing message
            // includes the code; console print gets the full description for
            // when someone shares a screenshot.
            let urlErr = error as? URLError
            let code = urlErr.map { String($0.code.rawValue) } ?? "?"
            let host = url.host ?? "?"
            let detail = "[\(code) \(host)] \(error.localizedDescription)"
            print("[ChatCompletionsClient] POST \(url.absoluteString) failed: \(error)")
            throw LlmError.network(detail)
        }
        guard let http = resp as? HTTPURLResponse else { throw LlmError.network("no http response · url=\(url.absoluteString)") }
        guard (200..<300).contains(http.statusCode) else {
            // Relay returns structured policy errors (`{error:"license_blocked",
            // message: "<friendly zh>"}`) for the 4 known fix-it-by-paying
            // states. We promote those to `.policy` so the UI can render a
            // 订阅 Pro CTA next to the message instead of just text. Unknown
            // bodies fall through to `.api` which dumps the first 400 bytes
            // — see also Self.parsePolicy.
            if let policy = Self.parsePolicy(body: data, status: http.statusCode) {
                throw policy
            }
            let bodyText = String(data: data, encoding: .utf8)?.prefix(400).description ?? ""
            throw LlmError.api(http.statusCode, bodyText)
        }

        if r.usesRelaySSE {
            // Parse the SSE response — concatenate `delta.content` from every
            // chunk. Usage chunk (the terminal one with `usage` instead of
            // `delta`) is ignored client-side — the relay logs it for billing.
            return try parseSSEContent(data: data, status: http.statusCode)
        }

        // Surface the raw body in the error when shape doesn't match — DeepSeek
        // ships occasional schema variants (reasoning_content alongside content,
        // null content with finish_reason='content_filter', etc.) and chasing
        // "LLM 返回格式异常" with no body was wasted iterations.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            let body = String(data: data, encoding: .utf8)?.prefix(400) ?? "<binary>"
            throw LlmError.api(http.statusCode, "返回结构异常 · body=\(body)")
        }
        // Some providers (DeepSeek v4-pro) put the answer in `reasoning_content`
        // alongside an empty `content`. Accept either.
        let content = (msg["content"] as? String) ?? (msg["reasoning_content"] as? String) ?? ""
        // Whitespace-only counts as empty — DeepSeek occasionally returns
        // "\n" / " " and our prior `.isEmpty` check missed it, letting the
        // whitespace flow into the parser and silently disappear (guard
        // showed "服务端返回空内容" with no diagnostic body).
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let body = String(data: data, encoding: .utf8)?.prefix(400) ?? "<binary>"
            throw LlmError.api(http.statusCode, "content 字段为空或仅空白 · body=\(body)")
        }
        return content
    }

    /// Walk a buffered SSE response and collect `delta.content` into one
    /// string. We rely on a buffered Data (not streamed bytes) because
    /// the existing caller surface returns the full text — chunking
    /// happens locally in `stream()` afterward. Robust to partial lines
    /// landing across chunk boundaries because the relay flushes whole
    /// `data:` frames.
    private func parseSSEContent(data: Data, status: Int) throws -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        var collected = ""
        var sawTerminator = false
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { sawTerminator = true; continue }
            guard let payloadData = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            else { continue }
            if let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let chunk = delta["content"] as? String {
                collected += chunk
            }
            // Usage chunk (terminal one with no delta) is implicitly skipped.
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let head = text.prefix(400)
            throw LlmError.api(status, "SSE 空内容 · sawTerminator=\(sawTerminator) head=\(head)")
        }
        return collected
    }

    // MARK: - simulated streaming (used by QuickChat)

    /// "Streaming" surface for QuickChat. We do NOT use the SSE
    /// `/chat/completions?stream=true` endpoint — DeepSeek's streaming endpoint
    /// proved unreliable for our model/account combo (silent empty SSE with no
    /// error body, no finish_reason; observed live on iOS build 212). Instead
    /// we call the regular non-streaming `chat(_:)` (rock-solid; what import
    /// already uses) and chunk the result locally so the rest of the pipeline
    /// (VerdictParser → SentenceChunker → TTS → UI bubble) sees the same
    /// incremental shape it always did.
    ///
    /// Trade-off: user waits ~2-5 s for the first character (no per-token
    /// streaming). In exchange the call is reliable and any HTTP-level error
    /// surfaces cleanly via the existing `chat()` error paths.
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // chat() throws with raw body included when content is
                    // empty / shape unexpected, so we don't need a separate
                    // emptiness check here.
                    let full = try await chat(messages)
                    // Chunk into ~3-char pieces with a 20 ms delay so the UI
                    // sees the same incremental shape it would from real SSE.
                    // ~150 chars/s — fast enough to keep up with TTS, slow
                    // enough to look like streaming, not a paste. The
                    // SentenceChunker still flushes on sentence boundaries so
                    // TTS fires as soon as the first complete sentence lands.
                    var idx = full.startIndex
                    while idx < full.endIndex {
                        let next = full.index(idx, offsetBy: 3, limitedBy: full.endIndex) ?? full.endIndex
                        continuation.yield(String(full[idx..<next]))
                        idx = next
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - errors

    enum LlmError: Error, LocalizedError {
        case notConfigured
        case network(String)
        /// Unknown / unstructured non-2xx — `detail` is the first 400 bytes
        /// of the body for engineer-side debugging. The user-facing string
        /// from `errorDescription` does NOT include `detail` (the cryptic JSON
        /// dump was the original "用户看不懂" complaint).
        case api(Int, String)
        case badResponse
        /// Backend policy error with a known shape: `{error, message}`. The
        /// `message` is the friendly Chinese string we WANT to show; `code`
        /// drives the call-to-action (subscribe vs. configure LLM).
        case policy(code: PolicyCode, message: String, httpStatus: Int)
        /// User hasn't yet accepted the global AI-feature data-sharing
        /// disclosure (App Store Guideline 5.1.1(i) / 5.1.2(i), 2026-06-09).
        /// Maps to RemoteFailure.Kind.consentRequired so UI can re-present
        /// the AIConsentGate sheet.
        case consentRequired

        /// Known backend error codes that mean "this is a payable problem,
        /// not a bug". Stays an enum so `RemoteFailure.from(_:)` can pattern
        /// match without stringly-typed checks.
        enum PolicyCode: String {
            case licenseBlocked = "license_blocked"
            case freeUsedUp = "free_used_up"
            case trialUsedUp = "trial_used_up"
            case quotaExceeded = "quota_exceeded"
        }

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "AI 还没配置好。打开「我的 → LLM 设置」，填入一个 API Key 就能用啦。"
            case .network(let d):
                // Detail includes URLError code + host + description so a
                // screenshot is enough to diagnose (timeout / DNS / TLS /
                // offline). Common URLError codes worth recognising at a
                // glance: -1001 timeout, -1003 host not found, -1004 cannot
                // connect, -1009 offline, -1200 TLS handshake.
                return "网络出错：\(d)（开着 VPN 的话试试关掉、或换个网络）"
            case .api(let c, let detail):
                // Earlier decision was to hide the detail because a 403 +
                // raw JSON looked like garbage. But "服务返回了错误（200）"
                // with no body context is impossible to debug — 200 with
                // our parser failing means wrong baseUrl, wrong model, or
                // a vendor schema variant we don't handle. Surface the
                // first 300 chars so users (or us in DM) can tell which.
                if detail.isEmpty {
                    return "AI 服务返回了错误（\(c)），稍后再试一次试试。"
                }
                let trimmed = detail.prefix(300)
                return "AI 服务返回了错误（\(c)）\n详情：\(trimmed)"
            case .badResponse:
                return "AI 返回的内容没看懂，再试一次试试。"
            case .policy(_, let message, _):
                return message
            case .consentRequired:
                return "请先阅读并同意 AI 功能的数据使用说明，再继续使用 AI。"
            }
        }
    }

    // MARK: - policy parsing

    /// Try to decode a backend policy error from the response body. Returns
    /// `nil` when the body isn't a recognised `{error, message}` shape — the
    /// caller then falls back to `.api` with the raw bytes.
    ///
    /// Kept static + non-throwing so the hot-path 4xx branch reads as a
    /// single `if let policy = … { throw policy }`.
    static func parsePolicy(body: Data, status: Int) -> LlmError? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let errorStr = obj["error"] as? String,
              let code = LlmError.PolicyCode(rawValue: errorStr) else {
            return nil
        }
        let serverMessage = (obj["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Prefer our own friendlier copy. The server message can be technical
        // ("¥59.9 买断" / "200K tokens" math) and isn't always what we want a
        // user staring at an LLM error to read. The server one is the
        // fallback when our static copy hasn't caught up to a new code.
        let friendly = Self.friendlyMessage(for: code, fallback: serverMessage)
        return .policy(code: code, message: friendly, httpStatus: status)
    }

    private static func friendlyMessage(for code: LlmError.PolicyCode, fallback: String) -> String {
        switch code {
        case .licenseBlocked:
            return "你目前是「网站买断」用户。想用 whatSub 内置 AI 需要订阅 Pro——或者去「我的 → LLM 设置」填一个自己的 API Key 也可以。"
        case .freeUsedUp:
            return "本月免费 AI 体验额度已经用完啦。订阅 Pro 解锁完整月度配额，或者去「我的 → LLM 设置」填自己的 Key 继续用。"
        case .trialUsedUp:
            return "桌面端试用额度已经用完。订阅 Pro 即可继续使用 AI 功能。"
        case .quotaExceeded:
            return "本月 AI 额度已经用完。下个月 1 号自动重置——想现在继续，可以升级套餐。"
        }
    }
}
