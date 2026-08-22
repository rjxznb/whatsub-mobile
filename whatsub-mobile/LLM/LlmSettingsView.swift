import SwiftUI

/// LLM 设置 — two stacked surfaces:
///
/// 1. **使用 whatsub 托管 AI**. Visibility and availability come from the
///    server-authoritative `llmEntitlements` matrix.
///
/// 2. **BYOK**. Only website-buyout accounts may use it; buyout + Pro users
///    can switch modes. A stored key is retained when the account cannot use
///    it, but it is not shown as an available mode or read by a call.
struct LlmSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var useManagedRelay: Bool = true
    @State private var baseUrl: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var saved: Bool = false

    /// Manual re-entry for the AI 数据使用说明 sheet — see same field +
    /// pattern in MeView. Convenient here too since LLM 设置 is exactly
    /// the screen a privacy-conscious user lands on to inspect data flow.
    /// 2026-06-09 (App Store Guideline 5.1.1/5.1.2 follow-up).
    @State private var showAIConsent: Bool = false

    private var entitlements: LlmEntitlements? { appState.effectiveLlmEntitlements }
    private var selectedMode: LlmMode { useManagedRelay ? .managedRelay : .byok }
    private var presentation: LlmSettingsPresentation {
        LlmSettingsPresentation(entitlements: entitlements, storedMode: selectedMode)
    }

    var body: some View {
        Form {
            // AI 数据使用说明 — 顶置一行,LLM 设置正好是用户最关心
            // 数据流向的页面,把"查看完整说明"的入口放在 toggle 之上,
            // 让他们先读再选。2026-06-09。
            Section {
                Button {
                    showAIConsent = true
                } label: {
                    HStack {
                        Label("AI 数据使用说明", systemImage: "checkmark.shield")
                            .foregroundStyle(.whatsubInk)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.whatsubInkFaint)
                    }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("点开查看 whatSub 在使用 AI 功能时收集和发送的数据细节,以及托管中转 / BYOK 两种模式下的数据流向。")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkFaint)
            }

            // BYOK-shadowed-by-relay detector. Common confusion mode:
            // user toggled relay OFF once, filled BYOK fields, then later
            // toggled relay back ON (or never toggled off in the first
            // place but still believes they "set up BYOK"). The BYOK
            // values get persisted but ChatCompletionsClient ignores them
            // entirely when relay is on. Without this banner the only
            // signal users have is the error host they see ("hmm, why
            // does it say eversay.cc?").
            if presentation.showsModePicker && useManagedRelay
                && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("BYOK key 已填但未生效", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.whatsubHighlight)
                        Text("当前「使用 whatsub 托管 LLM」开关是 ON,所有 AI 调用走我们的中转 relay,你下方填的 baseUrl / API Key / Model **完全被忽略**。\n\n想用自己的 key,先关掉下方开关。")
                            .font(.footnote)
                            .foregroundStyle(.whatsubInkSoft)
                        Button {
                            useManagedRelay = false
                            autosave()
                        } label: {
                            Label("关掉托管,改用我自己的 key", systemImage: "arrow.right.circle.fill")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.whatsubAccent)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                }
            }

            if presentation.showsModePicker {
                Section {
                    Picker("AI 模式", selection: $useManagedRelay) {
                        Text("托管 AI").tag(true)
                        Text("自己的 Key").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: useManagedRelay) { _ in autosave() }
                } header: {
                    Text("AI 模式").foregroundStyle(.whatsubInkMuted)
                }
            }

            if presentation.availableModes.contains(.managedRelay) {
            Section {
                Label("使用 whatSub 托管 AI", systemImage: "sparkles")
                    .foregroundStyle(.whatsubInk)
                Text("由服务端按账号权益和额度管理，无需填写 API Key。")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
            } header: {
                Text("托管模式").foregroundStyle(.whatsubInkMuted)
            } footer: {
                Text("托管模式会将 AI 功能所需的文本发送到 whatSub 托管服务处理。")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkFaint)
            }
            }

            // ---- BYOK fields — collapse when relay is on ----
            // 2026-06-09 — placeholders changed from specific provider names /
            // model strings ("https://api.deepseek.com/v1", "deepseek-v4-flash")
            // to generic OpenAI-compatible-shaped examples. App Store review
            // Guideline 5 (China DST/MIIT compliance) requires we don't
            // promote specific foreign LLM brand names in the app UI.
            if presentation.showsAPIKeyFields {
                Section(header: Text("接口地址").foregroundStyle(.whatsubInkMuted)) {
                    TextField("https://api.<your-provider>.com/v1", text: $baseUrl)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .foregroundStyle(.whatsubInk)
                }
                Section(header: Text("API Key").foregroundStyle(.whatsubInkMuted)) {
                    SecureField("sk-...", text: $apiKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .foregroundStyle(.whatsubInk)
                }
                Section(header: Text("模型").foregroundStyle(.whatsubInkMuted)) {
                    TextField("<model-name>", text: $model)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .foregroundStyle(.whatsubInk)
                    Menu {
                        ForEach(LlmModelCatalog.vendors, id: \.name) { vendor in
                            Section(vendor.name) {
                                ForEach(vendor.models, id: \.self) { suggestedModel in
                                    Button(suggestedModel) {
                                        model = suggestedModel
                                        if !vendor.baseURL.isEmpty {
                                            baseUrl = vendor.baseURL
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("从官方推荐列表选择", systemImage: "list.bullet.rectangle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.whatsubAccent)
                    }
                    Text("列表按厂商官网 2026-08-18 文档核对；也可以直接输入服务商自定义模型 ID。")
                        .font(.caption2)
                        .foregroundStyle(.whatsubInkFaint)
                }
                Section {
                    Button(action: save) {
                        HStack {
                            Spacer()
                            Text(saved ? "已保存" : "保存")
                                .fontWeight(.semibold)
                                .foregroundStyle(saved ? .whatsubHighlight : .whatsubAccent)
                            Spacer()
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.whatsubBg)
        .navigationTitle("LLM 设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .onChange(of: entitlements) { _ in load() }
        // Re-read AI consent disclosure — same view the app auto-presents
        // on first launch. Idempotent re-accept.
        .sheet(isPresented: $showAIConsent) {
            AIConsentGate(presenting: $showAIConsent)
        }
    }

    // ---- formatting helpers ----


    // ---- I/O ----

    private func load() {
        let s = LlmSettingsStore.load()
        useManagedRelay = LlmEntitlementPolicy.effectiveSettings(
            s, entitlements: entitlements
        ).useManagedRelay
        baseUrl = s.baseUrl
        apiKey = s.apiKey
        model = s.model
    }

    private func save() {
        var s = LlmSettings()
        s.useManagedRelay = useManagedRelay
        s.baseUrl = baseUrl.trimmingCharacters(in: .whitespaces)
        s.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        s.model = model.trimmingCharacters(in: .whitespaces)
        LlmSettingsStore.save(s)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }

    /// Toggling the relay flag writes immediately (no separate Save button)
    /// since it's a single-bool change and the user expects the quota row
    /// to appear/disappear right away.
    private func autosave() {
        var s = LlmSettingsStore.load()
        s.useManagedRelay = useManagedRelay
        LlmSettingsStore.save(s)
    }

}

#Preview {
    NavigationStack {
        LlmSettingsView()
            .environmentObject(AppState())
    }
    .preferredColorScheme(.dark)
}
