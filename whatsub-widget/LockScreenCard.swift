import SwiftUI

/// Lock-screen / Notification Center representation of the import-queue
/// Activity. Shown on all iOS 16.1+ devices regardless of Dynamic Island
/// support — this is the primary surface for users on iPhone 13 / 14
/// standard / SE.
///
/// Layout: icon + title row, divider, three stat blocks (进行中 / 完成 /
/// 失败), and an optional "最近：<title>" line for the most-recently-changed
/// import.
struct LockScreenCard: View {
    let state: ImportActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconForState)
                    .foregroundStyle(.whatsubAccent)
                Text(titleForState)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                Spacer()
            }
            Divider().background(Color.white.opacity(0.1))
            HStack(spacing: 12) {
                statBlock(label: "进行中", count: state.inProgress, color: .whatsubAccent)
                statBlock(label: "完成",   count: state.completed,  color: .green)
                statBlock(label: "失败",   count: state.failed,     color: .red.opacity(0.85))
            }
            if let title = state.recentTitle, !title.isEmpty {
                Text("最近：\(title)")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
                    .lineLimit(1)
            }
        }
        .padding(14)
    }

    private var iconForState: String {
        if state.inProgress > 0 { return "tray.and.arrow.down.fill" }
        if state.failed > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var titleForState: String {
        if state.inProgress > 0 { return "视频导入处理中" }
        if state.failed > 0 { return "部分导入失败" }
        return "全部完成"
    }

    private func statBlock(label: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.whatsubInkMuted)
        }
    }
}
