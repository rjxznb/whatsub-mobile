import SwiftUI

/// Loading spinner that flips to a "可能 VPN 拦截了 eversay.cc" warning
/// + 「查看 VPN 直连规则」 button when the underlying network call hasn't
/// returned after `stallSeconds` (default 5s).
///
/// **Why a dedicated component**: every screen that hits
/// `whatsub.eversay.cc` (corpus mine, roleplay scenarios, library list,
/// quota check, etc.) suffers the same Chinese-user-with-VPN failure
/// mode — VPN routes eversay.cc through the HK exit, TLS handshake
/// stalls 30-60s before URLSession times out. The plain `ProgressView()`
/// reveals nothing; users assume the app is broken when it's actually
/// the VPN. Surfacing a stall hint with one-tap access to the VPN
/// rule sheet shortens recovery time from "kill app + give up" to
/// "add one rule, problem solved permanently."
///
/// We deliberately do NOT actively probe eversay.cc to detect the
/// stall — the network call the user is waiting on IS the probe.
/// An additional probe round-trip would (a) waste cycles on the happy
/// path and (b) compete with the real request for the same VPN
/// chokepoint, possibly accelerating the timeout.
///
/// Caller usage:
///   ```swift
///   case .loading:
///       RelayLoadingView(label: "正在拉取收藏…")
///   ```
struct RelayLoadingView: View {
    var label: String? = nil
    var stallSeconds: Double = 5

    @State private var stalled = false
    @State private var showVPNHelp = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().tint(.whatsubAccent)
            if let label, !stalled {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
            }
            if stalled {
                VStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 28))
                        .foregroundStyle(.whatsubHighlight)
                    Text("加载有点慢…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.whatsubInk)
                    Text("可能是 VPN 把 `whatsub.eversay.cc` 拐去了海外节点导致 TLS 握手卡住。给 VPN 加一条直连规则可以一劳永逸解决。")
                        .font(.caption)
                        .foregroundStyle(.whatsubInkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button {
                        showVPNHelp = true
                    } label: {
                        Label("查看 VPN 设置方法", systemImage: "network.badge.shield.half.filled")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.whatsubAccent)
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(stallSeconds * 1_000_000_000))
            if !Task.isCancelled { stalled = true }
        }
        .sheet(isPresented: $showVPNHelp) { VPNRuleHelpSheet() }
    }
}
