import SwiftUI
import StoreKit

/// Full-screen hard paywall shown when the user is logged in but not unlocked
/// (no license, no buyout, trial expired). Offers the ¥18 buyout + restore.
/// No external "buy on website" link (App Store anti-steering).
struct PaywallView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager

    private let privacyURL = URL(string: "https://whatsub.eversay.cc/privacy")!
    // Apple's standard EULA — no custom terms page needed.
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()
                (Text("what").foregroundColor(.white) + Text("Sub").foregroundColor(.whatsubAccent))
                    .font(.custom("Caveat-Bold", size: 72))
                Text("解锁完整版")
                    .font(.title3).fontWeight(.semibold).foregroundStyle(.whatsubInk)

                VStack(alignment: .leading, spacing: 14) {
                    bullet("永久解锁全部功能")
                    bullet("公共语料库 · 单词卡 · 云端字幕")
                    bullet("一次买断，无需订阅")
                }
                .padding(.horizontal, 8)

                Spacer()

                if let err = store.lastError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { _ = await store.purchaseBuyout() }
                } label: {
                    HStack(spacing: 8) {
                        if store.purchaseInProgress { ProgressView().tint(.black) }
                        Text(buyTitle).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.whatsubAccent).foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(store.purchaseInProgress || store.buyoutProduct == nil)

                Button("恢复购买") { Task { await store.restore() } }
                    .font(.callout).foregroundStyle(.whatsubInkMuted)

                HStack(spacing: 18) {
                    Link("隐私政策", destination: privacyURL)
                    Link("服务条款", destination: termsURL)
                }
                .font(.caption).foregroundStyle(.whatsubInkFaint)

                Spacer().frame(height: 6)
            }
            .padding(.horizontal, 32)
        }
        .onAppear { store.start() }
    }

    private var buyTitle: String {
        if let p = store.buyoutProduct { return "解锁完整版 · \(p.displayPrice)" }
        return "解锁完整版"
    }

    private func bullet(_ s: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.whatsubAccent)
            Text(s).foregroundStyle(.whatsubInk)
            Spacer()
        }
    }
}
