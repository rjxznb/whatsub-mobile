import SwiftUI
import StoreKit

/// Shared subscription purchase UI: month/year buttons + 恢复购买 + the Apple-
/// required auto-renew disclosure + 隐私/EULA links. The CALLER decides whether to
/// show it (license-only); this view just sells. `onPurchased` fires after a
/// successful subscribe so callers can refresh quota or retry a blocked action.
struct SubscriptionOptionsView: View {
    @EnvironmentObject var store: StoreManager
    var onPurchased: (() -> Void)?

    private let privacyURL = URL(string: "https://whatsub.eversay.cc/privacy")!
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let m = store.subMonth { planButton(m, label: "包月") }
            if let y = store.subYear { planButton(y, label: "包年") }

            if let err = store.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }

            Button("恢复购买") { Task { await store.restore() } }
                .font(.callout).foregroundStyle(.whatsubInkMuted)

            Text("订阅自动续订，可随时在「设置 › Apple ID › 订阅」中取消。")
                .font(.caption2).foregroundStyle(.whatsubInkFaint)

            HStack(spacing: 16) {
                Link("隐私政策", destination: privacyURL)
                Link("服务条款", destination: termsURL)
            }
            .font(.caption2).foregroundStyle(.whatsubInkFaint)
        }
        // CRITICAL: this view is embedded in MeView's List. With the default button
        // style, a List row treats its whole content as ONE tap target and fires every
        // Button/Link in the row at once (tap 包月 → privacy link + 包年 + 恢复 all fire).
        // .borderless makes each control its own hit target. Harmless in ImportView's VStack.
        .buttonStyle(.borderless)
        .onAppear { store.start() }
    }

    private func planButton(_ product: Product, label: String) -> some View {
        Button {
            Task { if await store.purchaseSubscription(product) { onPurchased?() } }
        } label: {
            HStack {
                Text("\(label) · \(product.displayPrice)").fontWeight(.semibold)
                Spacer()
                if store.purchaseInProgress { ProgressView().tint(.black) }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Color.whatsubAccent)
            .foregroundColor(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(store.purchaseInProgress)
    }
}
