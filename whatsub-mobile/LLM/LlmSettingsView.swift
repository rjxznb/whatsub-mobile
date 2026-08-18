import SwiftUI

/// LLM 设置 — two stacked surfaces:
///
/// 1. **使用 whatsub 托管 LLM** (default ON, 2026-06-04). When on we route
///    `/chat/completions` to `whatsub.eversay.cc/api/llm/v1` with the
///    user's session bearer; the relay enforces tier-based monthly /
///    lifetime budgets and forces the cheap DeepSeek model server-side.
///    Monthly managed-relay quota is shown in 我的 → 云端同步 so it is
///    visible alongside the other cloud allowances.
///
/// 2. **BYOK 高级** (collapsed when relay is on). Lets a power user paste
///    their own provider config — survives the relay being down, lets
///    them use a cheaper model, etc. Default OFF; opt-in only.
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
            if useManagedRelay
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

            Section {
                Toggle(isOn: $useManagedRelay) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("使用 whatsub 托管 LLM")
                            .foregroundStyle(.whatsubInk)
                        Text("零配置开箱即用,Pro 用户用月度配额,免费 200K 体验包")
                            .font(.caption)
                            .foregroundStyle(.whatsubInkMuted)
                    }
                }
                .tint(.whatsubAccent)
                .onChange(of: useManagedRelay) { _ in autosave() }
            } header: {
                Text("中转模式").foregroundStyle(.whatsubInkMuted)
            } footer: {
                // 2026-06-10 — 显式标明接收方(Apple Guideline 5.1.2(i):
                // "Specify who the data is sent to")。
                // 深度求索 (DeepSeek) 是国内有 MIIT 备案的合规服务商,
                // 跟 China DST/Guideline 5 没冲突。
                Text("开启时:数据经 whatSub 国内服务器中转后,由「深度求索 (DeepSeek)」提供大模型处理。\n关闭后请在下方填入自己的 LLM API Key(BYOK),数据将直接从设备发给你所选择的服务商,不经过 whatSub。")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkFaint)
            }

            // ---- BYOK fields — collapse when relay is on ----
            // 2026-06-09 — placeholders changed from specific provider names /
            // model strings ("https://api.deepseek.com/v1", "deepseek-v4-flash")
            // to generic OpenAI-compatible-shaped examples. App Store review
            // Guideline 5 (China DST/MIIT compliance) requires we don't
            // promote specific foreign LLM brand names in the app UI.
            if !useManagedRelay {
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
        useManagedRelay = s.useManagedRelay
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
