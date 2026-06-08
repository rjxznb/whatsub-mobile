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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Group {
                    section(
                        title: "会发送什么内容",
                        body:
                            "• 字幕和短语文本(双语字幕翻译、AI 标黄重点词、AI 重译)\n" +
                            "• 你录的英文语音转出来的文字(对话陪练、实景口语跟读 — 录音不会上传,转文字在本机完成)\n" +
                            "• 你用 whatSub 拍照或从相册选择的图片经本机 OCR 识别出来的英文文字(拍照翻译、图片提取短语 — 照片本身不会上传)\n" +
                            "• 你在「语料库」里添加的英文短语和上下文句子"
                    )

                    section(
                        title: "会发送给谁",
                        body:
                            "默认使用 whatSub 托管的 AI 服务(由 whatSub 在国内服务器中转,接入合规的大模型服务商)。\n" +
                            "你也可以在「我的 → LLM 设置」关掉托管,改用自己注册的第三方大模型服务商账号(BYOK)— 这时数据会直接从你的设备发到你选的那家服务商。"
                    )

                    section(
                        title: "我们的服务器会做什么",
                        body:
                            "中转通道只在请求转发的瞬间触达字幕/语音/OCR 文本,处理完即丢弃,不长期存储你的输入内容。我们只为计费记录保留 token 用量统计(不含你输入的具体文字)。"
                    )

                    section(
                        title: "为什么需要这个授权",
                        body:
                            "翻译和 AI 分析的本质就是把文本发给一个大模型再拿回结果。Apple 要求我们必须在你按下「翻译 / AI 标黄 / 对话陪练」按钮之前,先告诉你这件事并征得你的同意。"
                    )
                }

                // Buttons — primary "同意并继续", secondary "退出 app"
                // (no AI use without consent; user can still browse Library
                // but AI features won't work).
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

                    HStack(spacing: 16) {
                        Link("查看隐私政策", destination: URL(string: "https://whatsub.eversay.cc/privacy")!)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.whatsubAccent)
                        Link("管理 AI 服务来源", destination: URL(string: "https://whatsub.eversay.cc/mobile#pro")!)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.whatsubAccent)
                    }
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
            Text("关于 AI 功能的数据使用")
                .font(.title2.weight(.bold))
                .foregroundStyle(.whatsubInk)
            Text("使用 whatSub 的 AI 翻译、AI 标黄、对话陪练、拍照翻译等功能前,请阅读并确认下面这些数据使用细节:")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
/// `v2` suffix on the key is intentional: it forces any user who acked the
/// old QuickChat-only gate (`quickchat.compliance.acked.v1`) to see the
/// expanded global gate at least once on this build, since the v1 wording
/// didn't disclose the managed-relay path or the per-feature data set.
///
/// `@MainActor` because `@Published` mutations want to drive SwiftUI updates;
/// `start()` is sync so view init can read it without async hops.
@MainActor
final class AIConsentStore: ObservableObject {
    static let shared = AIConsentStore()

    private static let key = "ai-consent.v2.accepted"

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
        UserDefaults.standard.bool(forKey: key)
    }
}
