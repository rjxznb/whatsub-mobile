import SwiftUI

/// End-of-session card (spec §6.5 [局末]).
struct QuickChatSummaryView: View {
    let phrases: [SessionPhrase]
    let completed: Set<String>
    let notes: [String: String]   // phraseNormalized → most recent error note
    let onPlayAgain: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("用对 \(completed.count) / \(phrases.count)")
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(.whatsubInk)
                Text(subtitle).font(.subheadline).foregroundStyle(.whatsubInkMuted)
            }
            VStack(spacing: 10) {
                ForEach(phrases) { p in row(for: p) }
            }
            .padding(.horizontal, 16)
            Spacer()
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Text("关闭").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.bordered).tint(.whatsubAccent)
                Button(action: onPlayAgain) {
                    Text("再来一局").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(.whatsubAccent)
            }
            .padding(20)
        }
        .padding(.top, 32)
    }

    private var subtitle: String {
        if completed.count == phrases.count { return "全用上了，干得漂亮 🎉" }
        if completed.isEmpty { return "下一局再试试 💪" }
        return "继续练，明天回捞剩下的"
    }

    @ViewBuilder
    private func row(for p: SessionPhrase) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: completed.contains(p.phraseNormalized) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(completed.contains(p.phraseNormalized) ? .green : .whatsubInkFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.phraseRaw).font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubInk)
                if let n = notes[p.phraseNormalized], !n.isEmpty {
                    Text(n).font(.caption).foregroundStyle(.whatsubInkMuted)
                } else if !completed.contains(p.phraseNormalized) {
                    Text("这一局没用上").font(.caption).foregroundStyle(.whatsubInkFaint)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
    }
}
