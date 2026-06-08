import Foundation

/// LLM config — talks to any /chat/completions endpoint. Default = DeepSeek
/// (api.deepseek.com), matching the desktop's default LLM slot. v1 supports
/// only this single endpoint shape; provider swap is via baseUrl/apiKey/model.
///
/// 2026-06-04: `useManagedRelay` added. When true, ChatCompletionsClient
/// ignores `baseUrl/apiKey/model` and instead routes through the whatsub-
/// hosted DeepSeek relay (Bearer = session token, model + budget enforced
/// server-side). New users default to true so Pro/Trial users get the
/// zero-config experience out of the box.
struct LlmSettings: Codable, Equatable {
    /// When true, route via `https://whatsub.eversay.cc/api/llm/v1` using
    /// the user's Pro session OR trial token as Bearer — BYOK fields below
    /// are ignored. Free users (no token) will get 401 at relay → caller
    /// surfaces the existing "AI 设置" or upsell sheet.
    var useManagedRelay: Bool = true
    // 2026-06-09 — BYOK default values dropped to empty strings to remove
    // brand-name mentions from the UI (App Store review Guideline 5: foreign
    // LLM brand names can't pass China DST/MIIT compliance). When relay is
    // OFF and these are empty, the LlmSettingsView fields show generic
    // placeholders (api.<your-provider>.com / <model-name>) which prompt the
    // user to supply whatever provider they prefer without us recommending one.
    var baseUrl: String = ""
    var apiKey: String = ""
    var model: String = ""

    /// True when EITHER relay mode is on (auth handled at call site by the
    /// presence of a session token) OR a BYOK key is filled.
    var isConfigured: Bool {
        if useManagedRelay { return true }
        return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case useManagedRelay
        case baseUrl, apiKey, model
    }

    init() {}

    /// Custom decoder so pre-2026-06-04 stored settings (no
    /// `useManagedRelay` field) default to `true` — flips existing TF
    /// testers to the relay path on the next launch without forcing them
    /// to revisit the settings screen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.useManagedRelay = (try? c.decode(Bool.self, forKey: .useManagedRelay)) ?? true
        self.baseUrl = (try? c.decode(String.self, forKey: .baseUrl)) ?? ""
        self.apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? ""
        self.model = (try? c.decode(String.self, forKey: .model)) ?? ""
    }
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
