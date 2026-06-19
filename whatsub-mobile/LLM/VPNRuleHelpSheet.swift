import SwiftUI

/// One-screen tutorial for adding a `whatsub.eversay.cc → 直连` rule in the
/// user's VPN app. Presented from the `ImportView` error UI when the LLM
/// relay call fails with a TLS / connection error and `useManagedRelay`
/// is on — the most common Chinese-user failure mode (VPN routing
/// eversay.cc through HK breaks TLS handshake).
///
/// We can't bypass system VPN from a regular iOS app (no public API for
/// per-host tunnel exclusion), so the only durable fix is on the user's
/// VPN side. Per-app rule strings cover Clash family + Shadowrocket +
/// Surge + Quantumult X — together >95% of the China power-user base.
struct VPNRuleHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct AppRule: Identifiable {
        let id = UUID()
        let app: String
        let rule: String
        let note: String?
    }

    private let rules: [AppRule] = [
        .init(app: "Clash / Mihomo / Stash", rule: "DOMAIN-SUFFIX,eversay.cc,DIRECT", note: "加在 rules 段最上面，覆盖默认匹配"),
        .init(app: "Shadowrocket", rule: "DOMAIN-SUFFIX,eversay.cc,DIRECT", note: "配置 → 规则 → 添加"),
        .init(app: "Surge", rule: "DOMAIN-SUFFIX,eversay.cc,DIRECT", note: "[Rule] 段顶部添加"),
        .init(app: "Quantumult X", rule: "host-suffix, eversay.cc, direct", note: "分流 → 规则 → 添加（注意小写）"),
        .init(app: "Loon", rule: "DOMAIN-SUFFIX,eversay.cc,DIRECT", note: "[Rule] 段顶部添加"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    ForEach(rules) { r in ruleCard(r) }
                    explanation
                }
                .padding(16)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("VPN 直连规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("一次配置，永久解决")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
            Text("中国大陆使用时，VPN 默认会把 `whatsub.eversay.cc` 拐去海外节点，触发 TLS 握手错误（-1200）。给 VPN 加一条「eversay.cc 走直连」就能让 YouTube 走 VPN、AI 解析走国内直连，两者同时工作。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func ruleCard(_ r: AppRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(r.app)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                Spacer()
                Button {
                    UIPasteboard.general.string = r.rule
                } label: {
                    Label("复制规则", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.whatsubAccent)
                .controlSize(.small)
            }
            Text(r.rule)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.whatsubInk)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
            if let n = r.note {
                Text(n)
                    .font(.caption2)
                    .foregroundStyle(.whatsubInkFaint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("自配 API Key 的用户可忽略")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
            Text("如果你在 「我的 → LLM 设置」里关了「whatsub 托管 LLM」并填了自己的 DeepSeek/OpenAI API Key，LLM 调用直接打厂商，不经我们服务器，VPN 也不会拦——这种情况下保持 VPN 开就行。")
                .font(.caption)
                .foregroundStyle(.whatsubInkFaint)
                .textSelection(.enabled)
        }
        .padding(.top, 8)
    }
}
