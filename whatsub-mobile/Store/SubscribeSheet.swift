import SwiftUI

/// Wraps SubscriptionOptionsView in a sheet so the 我的 page shows a single
/// 「订阅」entry button (less aggressive than inline price buttons); tapping it
/// opens the payment card here.
struct SubscribeSheet: View {
    var onPurchased: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("订阅 whatSub Pro")
                        .font(.title2.weight(.bold)).foregroundStyle(.whatsubInk)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• 50 个云端视频额度（免费 3 个）")
                        Text("• 单个视频 500MB / 60 分钟（免费 100MB / 20 分钟）")
                        Text("• 1000 个个人语料库额度（免费 50 个）")
                    }
                    .font(.subheadline).foregroundStyle(.whatsubInkMuted)
                    SubscriptionOptionsView(onPurchased: { onPurchased(); dismiss() })
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("订阅 Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
