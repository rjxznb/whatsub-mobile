import SwiftUI

/// Two-tier VPN split-routing guidance for mainland-China users.
///
/// Tier 1 (the hero, covers ~90%): **switch the VPN from 全局 to 规则 mode**.
/// Nothing to copy. Our API + CDN both resolve to Chinese Aliyun IPs
/// (whatsub.eversay.cc → 47.93.87.206, cdn.eversay.cc → Aliyun CDN nodes),
/// and essentially every mainstream rule set ships `GEOIP,CN,DIRECT`, so a
/// rule-mode client sends whatSub traffic direct and YouTube through the
/// proxy with zero user configuration.
///
/// NOTE: it is GEOIP — not any vendor domain rule — that saves us.
/// `eversay.cc` is our own domain; rule sets listing `aliyun.com` /
/// `alicdn.com` never match it. That's why tier 2 still exists.
///
/// Tier 2 (collapsed fallback): an explicit `DOMAIN-SUFFIX,eversay.cc,DIRECT`
/// line, for the setups GEOIP can't rescue — fake-ip DNS (where GEOIP with
/// `no-resolve` can't see a real IP) and slimmed-down rule sets with no
/// `GEOIP,CN` at all. One suffix rule covers BOTH whatsub.* and cdn.*.
///
/// We can't bypass a system VPN from a regular iOS app (no public API for
/// per-host tunnel exclusion), so the fix necessarily lives on the user's
/// VPN side. App coverage spans Clash family + Shadowrocket + Surge +
/// Quantumult X + Loon — together >95% of the China power-user base.
struct VPNRuleHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Where each client hides its mode switch (tier 1).
    /// `screenshot` is an OPTIONAL asset-catalog name — a labelled screenshot
    /// beats any amount of prose for "which row do I tap". Rows whose asset
    /// isn't in the bundle simply render text-only (see `screenshotView`), so
    /// adding a new one is: drop the PNG into
    /// `Assets.xcassets/VPNGuide<App>.imageset/` and name it here.
    private struct ModeHint: Identifiable {
        let id = UUID()
        let app: String
        let path: String
        var screenshot: String? = nil
    }

    /// The explicit direct rule per client (tier 2 fallback).
    private struct AppRule: Identifiable {
        let id = UUID()
        let app: String
        let rule: String
        let note: String?
    }

    @State private var showFallback = false

    private let modeHints: [ModeHint] = [
        .init(app: "Shadowrocket", path: "首页「全局路由」→ 选「配置」",
              screenshot: "VPNGuideShadowrocket"),
        .init(app: "Clash / Mihomo / Stash", path: "首页模式切换 → 选「规则」(Rule)"),
        .init(app: "Surge", path: "首页出站模式 → 选「规则模式」"),
        .init(app: "Quantumult X", path: "首页「分流」→ 关闭全局代理"),
        .init(app: "Loon", path: "首页出站模式 → 选「规则判定」"),
    ]

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
                    modeCard
                    fallbackSection
                    explanation
                }
                .padding(16)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("VPN 设置")
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
            Text("不用反复开关 VPN")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
            Text("whatSub 的数据（视频库、AI 解析、语料库）走国内服务器，播放 YouTube 走海外。只要 VPN 处在「规则模式」，两边会各走各的路，同时正常工作——问题只出在「全局模式」，它会把国内服务器也拐去海外节点，导致加载失败。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Tier 1 — the only step most users need.
    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.whatsubAccent)
                Text("把 VPN 切到「规则模式」就行")
                    .font(.headline)
                    .foregroundStyle(.whatsubInk)
            }
            Text("不用复制任何东西。主流机场/规则集都自带「国内直连」规则，whatSub 的服务器在国内，会被自动识别走直连。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(modeHints) { h in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(h.app)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.whatsubInk)
                                .frame(width: 132, alignment: .leading)
                            Text(h.path)
                                .font(.footnote)
                                .foregroundStyle(.whatsubInkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        screenshotView(h.screenshot)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.whatsubAccent.opacity(0.35), lineWidth: 1)
        )
    }

    /// Renders a labelled screenshot when that asset actually ships in the
    /// bundle. `UIImage(named:)` is the existence check — SwiftUI's
    /// `Image(name)` would draw an empty box for a missing asset, so a hint
    /// whose PNG hasn't been added yet stays clean text instead of a hole.
    @ViewBuilder
    private func screenshotView(_ name: String?) -> some View {
        if let name, let ui = UIImage(named: name) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.whatsubInkFaint.opacity(0.3), lineWidth: 1)
                )
                .padding(.leading, 132)
                .accessibilityLabel("设置位置示意图")
        }
    }

    /// Tier 2 — collapsed by default so it never competes with tier 1.
    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showFallback.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("切到规则模式还是不行？")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.whatsubInk)
                        Text("少数配置需要手动加一条直连规则")
                            .font(.caption)
                            .foregroundStyle(.whatsubInkFaint)
                    }
                    Spacer()
                    Image(systemName: showFallback ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.whatsubInkFaint)
                }
            }
            .buttonStyle(.borderless)

            if showFallback {
                Text("如果你的 VPN 用了 fake-ip DNS，或规则集被精简过（没有「国内直连」这条），就需要手动加一条。这一条同时覆盖 whatSub 的接口和视频 CDN。")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
                    .textSelection(.enabled)
                ForEach(rules) { r in ruleCard(r) }
            }
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubBg, in: RoundedRectangle(cornerRadius: 10))
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
