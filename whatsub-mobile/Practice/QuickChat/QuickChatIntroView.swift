import SwiftUI

/// First-launch tutorial sheet for the QuickChat / 对话陪练 feature. Explains
/// what it is, how it works, and what UI surfaces matter. Shown automatically
/// on the user's first launcher visit (gated by @AppStorage flag), and
/// re-accessible via a help icon in the launcher toolbar.
struct QuickChatIntroView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("quickchat.intro.acked.v1") private var acked: Bool = false

    private let cards: [Card] = [
        Card(symbol: "lightbulb.fill",
             title: "用你收藏的短语开口说",
             detail: "AI 会用你勾选的那几个短语编一段小情景对话，逼你在合适的时机把短语说出来。从「认得」走到「会用」。"),
        Card(symbol: "target",
             title: "不是聊天，是练习",
             detail: "顶部 3 个短语 checklist 实时点亮——AI 暗中判断你这一轮的英文里有没有正确用上对应短语。用对一个就 ✓ + 反馈音。"),
        Card(symbol: "mic.fill",
             title: "自动监听 + 打字兜底",
             detail: "默认进入后自动开麦，你说话就开始录，停顿 1.5 秒后自动转写发送。不想出声点底部键盘图标切换打字。"),
        Card(symbol: "bubble.left.fill",
             title: "卡住了点短语",
             detail: "想不起来怎么用，点顶部那个短语 chip → 弹出当初你收藏它时的英文原句，看一眼就能想起来。"),
        Card(symbol: "checkmark.seal.fill",
             title: "局末写入掌握度",
             detail: "5 轮结束（你可以改 3/5/10/∞）AI 自然收尾，客户端统计你用对了几个 → 写入「会用」掌握度。下次系统优先抽你还没说会的那些。"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    ForEach(cards) { card in cardView(card) }
                    Spacer().frame(height: 16)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("对话陪练")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) { ackButton }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("跳过") { dismiss() }
                }
            }
        }
    }

    // ---- pieces ----

    private struct Card: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title)
                    .foregroundStyle(.whatsubAccent)
                Text("对话陪练怎么用")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.whatsubInk)
            }
            Text("1 分钟读完，下次就能直接上手了。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.whatsubBgElev))
    }

    private func cardView(_ card: Card) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.whatsubAccent.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: card.symbol)
                    .font(.headline)
                    .foregroundStyle(.whatsubAccent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                Text(card.detail)
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

    private var ackButton: some View {
        Button {
            acked = true
            dismiss()
        } label: {
            Text("我知道了，开始选词")
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.whatsubAccent, in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
        .background(
            LinearGradient(colors: [.clear, Color.whatsubBg, Color.whatsubBg],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 100)
                .allowsHitTesting(false)
        )
    }

    /// Whether the user has already acked the intro. Use this from the
    /// launcher to decide whether to auto-present.
    static var hasAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: "quickchat.intro.acked.v1")
    }
}
