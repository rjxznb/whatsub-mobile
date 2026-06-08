import SwiftUI
import StoreKit

/// Shared subscription purchase UI: month/year buttons + 恢复购买 + the Apple-
/// required auto-renew disclosure + 隐私/EULA links. The CALLER decides whether to
/// show it (license-only); this view just sells. `onPurchased` fires after a
/// successful subscribe so callers can refresh quota or retry a blocked action.
///
/// 2026-06-09 — App Store review Guideline 3.1.2(c) flagged this view as missing
/// the required disclosures. Apple's checklist for an auto-renewable subscription
/// presented in-app:
///   • Title of subscription
///   • Length of subscription
///   • Price (and price-per-unit if applicable)
///   • Functional links to the privacy policy AND Terms of Use (EULA)
/// Rewrote each plan row to carry the title ("whatSub Pro") + length ("1 个月" /
/// "1 年") next to the price, and bumped the Privacy + EULA links from caption2
/// + ink-faint (almost invisible) up to footnote + accent with underline so the
/// reviewer (and any user) can spot and tap them on first glance.
struct SubscriptionOptionsView: View {
    @EnvironmentObject var store: StoreManager
    var onPurchased: (() -> Void)?

    private let privacyURL = URL(string: "https://whatsub.eversay.cc/privacy")!
    /// Apple's standard EULA. Switching to the standard EULA (vs. our own) gives
    /// reviewers a recognised link, simplifies the disclosure, and avoids a
    /// separate EULA-page maintenance burden.
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let m = store.subMonth {
                planButton(m, title: "whatSub Pro · 包月订阅", length: "1 个月")
            }
            if let y = store.subYear {
                planButton(y, title: "whatSub Pro · 包年订阅", length: "1 年")
            }

            if let err = store.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }

            Button("恢复购买") { Task { await store.restore() } }
                .font(.callout).foregroundStyle(.whatsubInkMuted)

            // Apple-mandated auto-renew disclosure. Stays as a small but legible
            // line — caption rather than caption2 so it's clearly readable.
            Text("订阅自动续订，可随时在「设置 › Apple ID › 订阅」中取消，下个计费周期前 24 小时关闭即不再续费。")
                .font(.caption).foregroundStyle(.whatsubInkMuted)
                .fixedSize(horizontal: false, vertical: true)

            // Privacy + EULA links — bumped to footnote + accent + underline.
            // Apple Guideline 3.1.2(c) wants these "functional"; reviewer must
            // be able to find + tap them inside the purchase flow without
            // hunting. .borderless on the parent VStack lets each Link
            // capture its own tap (default List-row behaviour treats the
            // whole row as one tap target).
            HStack(spacing: 20) {
                Link(destination: privacyURL) {
                    Text("隐私政策")
                        .font(.footnote.weight(.semibold))
                        .underline()
                        .foregroundStyle(.whatsubAccent)
                }
                Link(destination: termsURL) {
                    Text("服务条款 (EULA)")
                        .font(.footnote.weight(.semibold))
                        .underline()
                        .foregroundStyle(.whatsubAccent)
                }
            }
            .padding(.top, 4)
        }
        // CRITICAL: this view is embedded in MeView's List. With the default button
        // style, a List row treats its whole content as ONE tap target and fires every
        // Button/Link in the row at once (tap 包月 → privacy link + 包年 + 恢复 all fire).
        // .borderless makes each control its own hit target. Harmless in ImportView's VStack.
        .buttonStyle(.borderless)
        .onAppear { store.start() }
    }

    /// One subscription plan row. Carries Apple's required four pieces of info:
    /// `title` (subscription name), `length` (calendar duration), `product.displayPrice`
    /// (price, localized by StoreKit), and the secondary "续订" disclosure
    /// underneath. Layout puts title + length on the leading edge so a reviewer
    /// scanning the screen sees what they're buying without parsing the price tag.
    private func planButton(_ product: Product, title: String, length: String) -> some View {
        Button {
            Task { if await store.purchaseSubscription(product) { onPurchased?() } }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    Text(product.displayPrice).fontWeight(.semibold)
                    if store.purchaseInProgress { ProgressView().tint(.black) }
                }
                Text("\(length) · 到期自动续订，可随时取消")
                    .font(.caption2)
                    .opacity(0.78)
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
