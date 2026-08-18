import Foundation

/// BYOK suggestions checked against vendor documentation on 2026-08-18.
/// These are providers that expose the `/chat/completions` wire shape used by
/// the mobile BYOK client; users can still type any deployment/model ID below.
/// Native-only APIs such as Anthropic's Messages API remain desktop-only until
/// the mobile client gains a dedicated protocol adapter.
struct LlmModelVendor {
    let name: String
    let baseURL: String
    let models: [String]
    let documentationURL: URL
}

enum LlmModelCatalog {
    static let vendors: [LlmModelVendor] = [
        LlmModelVendor(
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o-mini"],
            documentationURL: URL(string: "https://platform.openai.com/docs/models")!
        ),
        LlmModelVendor(
            name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            models: ["gemini-3.7-flash", "gemini-3.5-flash", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"],
            documentationURL: URL(string: "https://ai.google.dev/gemini-api/docs/models")!
        ),
        LlmModelVendor(
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-v4-flash", "deepseek-v4-pro"],
            documentationURL: URL(string: "https://api-docs.deepseek.com/")!
        ),
        LlmModelVendor(
            name: "阿里 Qwen",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            models: ["qwen3.7-max", "qwen3.7-plus", "qwen3.6-flash", "qwen3-coder-plus", "qwen-plus"],
            documentationURL: URL(string: "https://www.alibabacloud.com/help/en/model-studio/models")!
        ),
        LlmModelVendor(
            name: "智谱 GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            models: ["glm-5", "glm-4.6", "glm-4-plus", "glm-4-flash"],
            documentationURL: URL(string: "https://docs.bigmodel.cn/cn/guide/models")!
        ),
        LlmModelVendor(
            name: "MiniMax",
            baseURL: "https://api.minimaxi.com/v1",
            models: ["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2.1", "MiniMax-Text-01"],
            documentationURL: URL(string: "https://platform.minimaxi.com/document/")!
        ),
        LlmModelVendor(
            name: "Kimi (Moonshot)",
            baseURL: "https://api.moonshot.cn/v1",
            models: ["kimi-k3", "kimi-k2.6", "kimi-k2.5", "kimi-k2-thinking", "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"],
            documentationURL: URL(string: "https://platform.moonshot.cn/docs/intro")!
        ),
    ]
}
