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

    init(settings: LlmSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    // MARK: - non-streaming (unchanged caller surface)

    func chat(_ messages: [ChatMessage]) async throws -> String {
        guard settings.isConfigured, let url = URL(string: "\(settings.baseUrl)/chat/completions") else {
            throw LlmError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "model": settings.model,
            "stream": false,
            "temperature": 0.3,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw LlmError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw LlmError.network("no http") }
        guard (200..<300).contains(http.statusCode) else {
            throw LlmError.api(http.statusCode, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LlmError.badResponse
        }
        return content
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
                    let full = try await chat(messages)
                    // Empty content body still possible (provider returns 200
                    // with an empty `content` string). Surface as a clear error
                    // instead of completing silently.
                    if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw LlmError.api(200, "LLM 返回内容为空（content 字段空字符串）")
                    }
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

    // MARK: - errors (unchanged)

    enum LlmError: Error, LocalizedError {
        case notConfigured, network(String), api(Int, String), badResponse
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "请先在「我的 → LLM 设置」填入 API Key"
            case .network(let d): return "网络失败：\(d)"
            // Include the diagnostic detail — caller often packs useful info
            // (server error body, "content 字段空字符串", etc.) and dropping it
            // forced us to chase ghosts the first time QuickChat went silent.
            case .api(let c, let detail):
                return detail.isEmpty
                    ? "LLM 接口错误（\(c)）"
                    : "LLM 接口错误（\(c)）：\(detail)"
            case .badResponse: return "LLM 返回格式异常"
            }
        }
    }
}
