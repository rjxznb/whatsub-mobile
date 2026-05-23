import Foundation

/// openai-compatible LLM config (v1 supports only this provider). Default =
/// DeepSeek, matching the desktop's default openaiCompatible slot.
struct LlmSettings: Codable, Equatable {
    var baseUrl: String = "https://api.deepseek.com/v1"
    var apiKey: String = ""
    var model: String = "deepseek-chat"

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
