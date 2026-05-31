import Foundation

/// Translates English text → Chinese for the long-press "显示中文" UX in
/// chat bubbles. Two providers:
///
/// - `mymemory`: free, no API key needed, ~5000 chars/day per IP. Quality is
///   passable for short conversational sentences but can produce funky output
///   for idioms or complex grammar.
/// - `llm`: uses the user's BYOK LLM (ChatCompletionsClient) with a terse
///   translation prompt. Better quality, slower, costs tokens — used as the
///   "用 AI 重译" escape hatch.
enum BubbleTranslator {

    enum Provider { case mymemory, llm }

    static func translate(_ text: String, provider: Provider) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        switch provider {
        case .mymemory: return try await translateViaMyMemory(trimmed)
        case .llm:      return try await translateViaLLM(trimmed)
        }
    }

    // ---- MyMemory ----

    private static func translateViaMyMemory(_ text: String) async throws -> String {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "en|zh-CN"),
        ]
        guard let url = components.url else { throw TranslateError.badRequest }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslateError.httpError((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = obj["responseData"] as? [String: Any],
              let translatedText = responseData["translatedText"] as? String else {
            throw TranslateError.badResponse
        }
        return translatedText
    }

    // ---- LLM ----

    private static func translateViaLLM(_ text: String) async throws -> String {
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else { throw TranslateError.llmNotConfigured }
        let client = ChatCompletionsClient(settings: settings)
        let sys = ChatMessage(role: "system", content:
            "You are a precise English-to-Chinese translator for conversational sentences. " +
            "Output ONLY the Chinese translation — no quotes, no romanization, no explanation. " +
            "Use natural conversational Chinese, including Chinese punctuation (。？！).")
        let usr = ChatMessage(role: "user", content: text)
        let response = try await client.chat([sys, usr])
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranslateError: Error, LocalizedError {
        case badRequest
        case httpError(Int)
        case badResponse
        case llmNotConfigured

        var errorDescription: String? {
            switch self {
            case .badRequest: return "翻译请求出错"
            case .httpError(let code): return "翻译失败（HTTP \(code)）"
            case .badResponse: return "翻译响应解析失败"
            case .llmNotConfigured: return "请先在「我的 → LLM 设置」填入 API Key"
            }
        }
    }
}
