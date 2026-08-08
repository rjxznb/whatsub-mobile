import SwiftUI

struct AnalysisDiagnosticSheet: View {
    static let copyButtonTitle = "复制诊断信息"

    let report: AnalysisDiagnosticReport
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("以下信息不包含字幕正文、API Key 或登录凭证。复制后发给客服即可定位解析停在哪一步。")
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkMuted)

                    Text(report.copyText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.whatsubInkSoft)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = report.copyText
                        copied = true
                    } label: {
                        Label(
                            copied ? "已复制" : Self.copyButtonTitle,
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.whatsubAccent)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("AI 解析诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
