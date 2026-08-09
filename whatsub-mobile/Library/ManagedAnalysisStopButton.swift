import SwiftUI

struct ManagedAnalysisStopButton: View {
    let isBusy: Bool
    let onConfirm: () -> Void

    @State private var isConfirming = false

    var body: some View {
        Button(isBusy ? "正在停止…" : "停止") {
            isConfirming = true
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .disabled(isBusy)
        .confirmationDialog(
            "停止 AI 解析？",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("停止解析", role: .destructive) {
                onConfirm()
            }
            Button("继续解析", role: .cancel) {}
        } message: {
            Text("已完成的翻译会保留，未完成部分将停止解析，之后可以继续。")
        }
    }
}
