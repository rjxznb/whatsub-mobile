import SwiftUI
import UIKit

/// Step-by-step guide for downloading Premium English TTS voices on iOS.
/// Used by VoiceSettingsView; surfaces both via a help icon and an automatic
/// banner when no premium/enhanced voice is detected.
struct PremiumVoiceGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [Step] = [
        Step(num: 1, title: "打开「设置」",
             detail: "在 iPhone 主屏找到「设置」app 图标，点击进入。",
             symbol: "gearshape.fill"),
        Step(num: 2, title: "点击「辅助功能」",
             detail: "在「设置」里向下滚动，找到「辅助功能」（图标是一个人形）。",
             symbol: "accessibility"),
        Step(num: 3, title: "进入「朗读内容」",
             detail: "在「辅助功能」里找到「朗读内容」并点击进入。",
             symbol: "text.bubble.fill"),
        Step(num: 4, title: "点击「语音」",
             detail: "在「朗读内容」页面找到「语音」选项。",
             symbol: "speaker.wave.2.fill"),
        Step(num: 5, title: "选「英语」",
             detail: "在语言列表里找到「英语」并点击。",
             symbol: "globe"),
        Step(num: 6, title: "下载标有 Premium 的语音",
             detail: "在英语语音列表里找标有 \"Premium\" 标签的语音（例如 Ava、Evan、Zoe、Noelle），点进去然后按右上角下载按钮。",
             symbol: "arrow.down.circle.fill"),
        Step(num: 7, title: "等下载完成",
             detail: "Premium 语音约 500MB。下载完无需重启 whatsub，下次对话陪练自动用新语音。",
             symbol: "checkmark.seal.fill"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    ForEach(steps) { step in stepCard(step) }
                    actionFooter
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("下载教程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // ---- header ----

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.whatsubAccent)
                Text("Siri 同款神经语音")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.whatsubInk)
            }
            Text("iOS 16+ 自带 Premium 神经语音 (Ava / Evan / Zoe 等)，听感跟 Siri 一致。系统不预装，要手动下载一次 (~500MB)，下完后 whatsub 自动用最好的那个。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.whatsubBgElev))
    }

    // ---- step cards ----

    private struct Step: Identifiable {
        let num: Int
        let title: String
        let detail: String
        let symbol: String
        var id: Int { num }
    }

    private func stepCard(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.whatsubAccent.opacity(0.18))
                    .frame(width: 36, height: 36)
                Text("\(step.num)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.whatsubAccent)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: step.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.whatsubAccent)
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.whatsubInk)
                }
                Text(step.detail)
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    // ---- action footer ----

    private var actionFooter: some View {
        VStack(spacing: 10) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("打开系统设置", systemImage: "gear")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.whatsubAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            Text("⚠️ iOS 不允许 app 跳到「朗读内容」深路径——按钮打开的是 whatsub 自己的设置页，请从那里返回上一级，再进「辅助功能 → 朗读内容」。")
                .font(.caption2)
                .foregroundStyle(.whatsubInkFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
        .padding(.top, 4)
    }
}
