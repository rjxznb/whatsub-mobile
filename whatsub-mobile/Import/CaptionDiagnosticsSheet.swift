import SwiftUI

/// Renders CaptionExtractor's event log so users can see exactly which
/// step of the extraction pipeline died. Surfaced from ImportView's
/// .extractFailed phase via a 「查看诊断」 button next to 「重试」.
///
/// Why a sheet (vs. an inline expander): the log can be 30-80 events
/// long after a real failure (every fetch seen, every nudge fired, every
/// timedtext mismatch). Inline would crowd the failure CTAs that we
/// actually want users to act on (推送到桌面端 / 重试). Sheet keeps the
/// primary screen tight and the diagnostic accessible.
///
/// 「复制」 toolbar action — most useful when the user is sending us a
/// support message. They don't need to type the events, just paste.
struct CaptionDiagnosticsSheet: View {
    let log: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("以下是字幕提取过程中每一步发生的事件，按时间从上到下排列。如果遇到反复抓不到字幕的视频，可以「复制」后发给我们排查。")
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkMuted)

                    if log.isEmpty {
                        Text("(无事件)")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.whatsubInkFaint)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.whatsubInkSoft)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("诊断信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = log.joined(separator: "\n")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .disabled(log.isEmpty)
                }
            }
        }
    }
}
