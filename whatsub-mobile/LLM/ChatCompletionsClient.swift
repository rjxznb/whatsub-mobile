import Foundation

struct ChatMessage { let role: String; let content: String }

/// Minimal non-streaming /chat/completions client. Wire format follows the
/// industry-standard "chat completions" JSON shape (model + messages + a
/// single text response) that most modern LLM providers implement —
/// DeepSeek, Moonshot, Zhipu, etc. The user configures baseUrl + apiKey +
/// model in 我的 → LLM 设置; this client just POSTs.
///
/// (The desktop streams via SSE; for a batch import job we take the full
/// response — simpler + adequate behind a progress bar.)
struct ChatCompletionsClient {
    let settings: LlmSettings

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
        do { (data, resp) = try await URLSession.shared.data(for: req) }
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
