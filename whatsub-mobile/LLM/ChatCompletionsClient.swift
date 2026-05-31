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

    // MARK: - streaming (new, for QuickChat)

    /// Yields each `delta.content` chunk as it arrives. Terminates on the
    /// `data: [DONE]` SSE sentinel. Network/parse errors propagate via the
    /// stream's throwing finish.
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard settings.isConfigured,
                          let url = URL(string: "\(settings.baseUrl)/chat/completions") else {
                        throw LlmError.notConfigured
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 120
                    let body: [String: Any] = [
                        "model": settings.model,
                        "stream": true,
                        "temperature": 0.3,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        throw LlmError.network("no http")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Drain a bit of body for the error context.
                        var sample = ""
                        for try await line in bytes.lines {
                            sample += line
                            if sample.count >= 200 { break }
                        }
                        throw LlmError.api(http.statusCode, sample)
                    }

                    for try await line in bytes.lines {
                        // SSE: each event is a `data: ...` line, plus blank line. We
                        // only care about the data lines; `bytes.lines` already gives
                        // them stripped of trailing newlines and skips empty lines.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            break
                        }
                        if let data = payload.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let chunk = delta["content"] as? String,
                           !chunk.isEmpty {
                            continuation.yield(chunk)
                        }
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
            case .api(let c, _): return "LLM 接口错误（\(c)）"
            case .badResponse: return "LLM 返回格式异常"
            }
        }
    }
}
