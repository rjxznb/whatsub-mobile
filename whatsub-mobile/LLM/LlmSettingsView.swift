import SwiftUI

/// LLM 设置 — two stacked surfaces:
///
/// 1. **使用 whatsub 托管 LLM** (default ON, 2026-06-04). When on we route
///    `/chat/completions` to `whatsub.eversay.cc/api/llm/v1` with the
///    user's session bearer; the relay enforces tier-based monthly /
///    lifetime budgets and forces the cheap DeepSeek model server-side.
///    The "quota" section shows used/limit/tier so the user knows how
///    much they have left without leaving the screen.
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

    @State private var quota: LlmQuota?
    @State private var quotaError: String?
    @State private var quotaLoading: Bool = false

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

            // ---- Quota panel (only when relay is on) ----
            if useManagedRelay {
                Section {
                    quotaBody
                } header: {
                    Text("本月额度").foregroundStyle(.whatsubInkMuted)
                }
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
        .onAppear {
            load()
            Task { await reloadQuota() }
        }
        .refreshable { await reloadQuota() }
        // Re-read AI consent disclosure — same view the app auto-presents
        // on first launch. Idempotent re-accept.
        .sheet(isPresented: $showAIConsent) {
            AIConsentGate(presenting: $showAIConsent)
        }
    }

    @ViewBuilder
    private var quotaBody: some View {
        if quotaLoading && quota == nil {
            HStack { Spacer(); ProgressView().tint(.whatsubAccent); Spacer() }
                .padding(.vertical, 6)
        } else if let q = quota {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tierLabel(q.tier))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.whatsubInk)
                    Spacer()
                    Text(formatUsage(q))
                        .font(.caption.monospaced())
                        .foregroundStyle(.whatsubInkMuted)
                }
                ProgressView(value: usagePct(q))
                    .tint(usagePct(q) > 0.9 ? .red : .whatsubAccent)
                Text(footerNote(for: q))
                    .font(.caption2)
                    .foregroundStyle(.whatsubInkMuted)
            }
            .padding(.vertical, 2)
        } else if let err = quotaError {
            // 403 license_blocked / free_used_up / etc all surface as
            // friendly server-supplied Chinese here. The body is long-
            // form, so let it wrap rather than truncating.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    useManagedRelay = false
                    autosave()
                } label: {
                    Label("关闭托管 · 改用自己的 API key", systemImage: "wrench.adjustable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.whatsubAccent)
                }
            }
        } else if appState.session == nil {
            Text("请先登录后查看额度")
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
        } else {
            Text("—")
                .font(.footnote)
                .foregroundStyle(.whatsubInkFaint)
        }
    }

    // ---- formatting helpers ----

    private func tierLabel(_ tier: String) -> String {
        switch tier {
        case "pro": return "已订阅 Pro"
        case "trial": return "桌面试用"
        case "free": return "免费体验"
        default: return tier
        }
    }

    /// "1.2k / 5.0M tokens" — friendly summed read of used/limit.
    private func formatUsage(_ q: LlmQuota) -> String {
        "\(short(q.used)) / \(short(q.limit)) tokens"
    }

    private func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func usagePct(_ q: LlmQuota) -> Double {
        guard q.limit > 0 else { return 0 }
        return min(1.0, Double(q.used) / Double(q.limit))
    }

    private func footerNote(for q: LlmQuota) -> String {
        if q.tier == "free" {
            return "免费体验包 LIFETIME,用完后请升级 Pro 或开启 BYOK"
        }
        if q.tier == "pro", q.periodResetAt > 0 {
            let date = Date(timeIntervalSince1970: Double(q.periodResetAt) / 1_000)
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "zh_CN")
            fmt.dateStyle = .medium
            return "下次重置:\(fmt.string(from: date))"
        }
        return ""
    }

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
        if useManagedRelay {
            Task { await reloadQuota() }
        }
    }

    @MainActor
    private func reloadQuota() async {
        guard let token = appState.session?.sessionToken else { return }
        quotaLoading = true
        quotaError = nil
        do {
            quota = try await WhatsubAPI.shared.llmQuota(token: token)
        } catch let e as APIError {
            quotaError = e.chinese
        } catch {
            quotaError = "额度查询失败:\(error.localizedDescription)"
        }
        quotaLoading = false
    }
}

#Preview {
    NavigationStack {
        LlmSettingsView()
            .environmentObject(AppState())
    }
    .preferredColorScheme(.dark)
}
