import SwiftUI

/// Global one-time consent for AI features (App Store Guideline 5.1.1(i) /
/// 5.1.2(i), 2026-06-09).
///
/// Apple rejected build 293 with: "the app appears to share the user's personal
/// data with a third-party AI service but the app does not clearly explain what
/// data is sent, identify who the data is sent to, and ask the user's permission
/// before sharing the data."
///
/// This view replaces the old QuickChat-only `QuickChatComplianceGate` (which
/// only covered one feature and had outdated copy claiming "whatSub 不内置任何
/// 语言模型服务" — false since the managed-LLM relay shipped 2026-06-04). The
/// new gate is presented at the application root before any AI surface becomes
/// reachable; once accepted, the flag survives reinstall (UserDefaults backed)
/// and the user never sees it again.
///
/// As defense-in-depth, `ChatCompletionsClient.chat(_:)` also checks the
/// consent flag itself and throws `LlmError.consentRequired` if the gate
/// somehow wasn't shown — that error maps to RemoteFailure.Kind.consentRequired
/// so a kind-aware UI can re-present the gate instead of leaving the user
/// stuck on an opaque error.
struct AIConsentGate: View {
    @Binding var presenting: Bool
    @ObservedObject private var store = AIConsentStore.shared

    var body: some View {
        // 文案大幅精简(2026-06-09 round 2):用户反馈"描述太多用词太专业,
        // 没耐心看完也看不懂"。原版四块卡片合并成三块,每块一句话,
        // 删去元解释(为什么需要这个授权)和"token / OCR / BYOK"等术语,
        // 保留 Apple Guideline 5.1.2(i) 的三项硬要求:发什么内容、发给谁、
        // 怎么处理。整页可以在 10 秒内读完。
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Group {
                    section(
                        title: "会发送什么内容",
                        body:
                            "视频字幕和你收藏的英文短语、对话陪练时你说的话(在本机转为文字后)、" +
                            "拍照翻译时识别出的文字。\n\n" +
                            "录音和照片本身不会上传,只发送转写或识别后的文字。"
                    )

                    section(
                        title: "发送给谁",
                        body:
                            "默认通过 whatSub 在国内的服务器中转,最终由「深度求索 (DeepSeek)」提供大模型处理。" +
                            "该服务商已取得国内《生成式人工智能服务管理暂行办法》备案,数据全程在中国大陆境内流转。\n\n" +
                            "也可在「我的 → LLM 设置」关闭托管,改用你自己的 API Key,那时数据将直接从你的设备发给你所选择的服务商,不经过 whatSub 服务器。"
                    )

                    section(
                        title: "如何保管",
                        body:
                            "中转服务器只在转发那一刻接触你的内容,处理完后不再保留,也不会用于其他用途。\n\n" +
                            "仅保留每月调用次数用于计费,不含具体文字内容。"
                    )
                }

                VStack(spacing: 10) {
                    Button {
                        store.accept()
                        presenting = false
                    } label: {
                        Text("同意并继续")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent).tint(.whatsubAccent)

                    Link("查看完整隐私政策", destination: URL(string: "https://whatsub.eversay.cc/privacy")!)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.whatsubAccent)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
        .background(Color.whatsubBg.ignoresSafeArea())
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 36))
                .foregroundStyle(.whatsubAccent)
            Text("AI 功能数据使用说明")
                .font(.title2.weight(.bold))
                .foregroundStyle(.whatsubInk)
            Text("使用翻译、AI 标黄、对话陪练、拍照翻译等功能前,请阅读并确认以下数据处理方式。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.whatsubInk)
            Text(body)
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// UserDefaults-backed singleton storing the global AI consent acceptance.
/// Version suffix on the key bumps whenever the disclosure copy materially
/// changes — forces any user who acked the previous version to re-read +
/// re-accept on the next launch, so consent is meaningful for what we
/// actually disclose.
///
///   v1 → 老 QuickChatComplianceGate (claimed "whatSub 不内置 LLM" — false
///        since the managed relay shipped 2026-06-04)
///   v2 → 2026-06-09 first global gate but vague recipient ("合规的大模型
///        服务商"); Apple rejected build 298 for not naming the recipient
///   v3 → 2026-06-10 names DeepSeek explicitly in the "发送给谁" section
///        (Apple Guideline 5.1.1/5.1.2 — "specify who the data is sent to")
///
/// `@MainActor` because `@Published` mutations drive SwiftUI updates;
/// `nonisolated static var hasAcceptedRaw` lets non-UI code (chat client
/// defense gate) read the flag.
@MainActor
final class AIConsentStore: ObservableObject {
    static let shared = AIConsentStore()

    private static let key = "ai-consent.v3.accepted"

    @Published private(set) var hasAccepted: Bool

    private init() {
        self.hasAccepted = UserDefaults.standard.bool(forKey: Self.key)
    }

    func accept() {
        UserDefaults.standard.set(true, forKey: Self.key)
        hasAccepted = true
    }

    /// Non-MainActor static read for use from non-UI code (e.g.,
    /// `ChatCompletionsClient.chat()`). UserDefaults read is thread-safe.
    nonisolated static var hasAcceptedRaw: Bool {
        UserDefaults.standard.bool(forKey: "ai-consent.v3.accepted")
    }
}
