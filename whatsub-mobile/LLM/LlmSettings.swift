import Foundation

/// LLM config — talks to any /chat/completions endpoint. Default = DeepSeek
/// (api.deepseek.com), matching the desktop's default LLM slot. v1 supports
/// only this single endpoint shape; provider swap is via baseUrl/apiKey/model.
struct LlmSettings: Codable, Equatable {
    var baseUrl: String = "https://api.deepseek.com/v1"
    var apiKey: String = ""
    // DeepSeek deprecated `deepseek-chat` / `deepseek-reasoner` aliases as of
    // 2026. New canonical names: `deepseek-v4-flash` (non-thinking, primary)
    // and `deepseek-v4-pro` (thinking). The old aliases still resolve for the
    // non-streaming endpoint but the streaming endpoint may return empty for
    // them — caught us once (QuickChat opening turn silent). Use the new name.
    var model: String = "deepseek-v4-flash"

    var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Persists LlmSettings in the Keychain (the apiKey is sensitive) under one item.
enum LlmSettingsStore {
    private static let service = "cc.eversay.whatsub.mobile.llm"
    private static let account = "llm-settings"

    static func load() -> LlmSettings {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = try? JSONDecoder().decode(LlmSettings.self, from: data) else {
            return LlmSettings()
        }
        return s
    }

    static func save(_ s: LlmSettings) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
