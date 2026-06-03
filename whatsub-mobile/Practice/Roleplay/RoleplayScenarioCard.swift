import SwiftUI

/// One scene card in the 角色扮演 picker. Tappable. Shows title, scene
/// description, role assignments, difficulty stars, and the vocab hints
/// the LLM is expected to drill in this session.
struct RoleplayScenarioCard: View {
    let scenario: RoleplayScenario
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(scenario.title)
                        .font(.headline)
                        .foregroundStyle(.whatsubInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    difficultyStars
                }

                // Roles: "你: 旅客 · AI: 海关"
                HStack(spacing: 6) {
                    Text("你:").font(.caption).foregroundStyle(.whatsubInkFaint)
                    Text(scenario.userRole)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.whatsubAccent)
                    Text("·").font(.caption).foregroundStyle(.whatsubInkFaint)
                    Text("AI:").font(.caption).foregroundStyle(.whatsubInkFaint)
                    Text(scenario.agentRole)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.whatsubInk)
                    Spacer(minLength: 0)
                }

                Text(scenario.setup)
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !scenario.vocabHints.isEmpty {
                    hintChips
                }

                HStack(spacing: 6) {
                    Spacer()
                    Text("开始对话")
                        .font(.footnote.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.whatsubAccent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var difficultyStars: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                Image(systemName: i <= scenario.difficulty ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(i <= scenario.difficulty ? Color.yellow : Color.whatsubInkFaint)
            }
        }
    }

    @ViewBuilder
    private var hintChips: some View {
        // Wrap to multi-line when the row overflows.
        FlowLayout(spacing: 6) {
            ForEach(scenario.vocabHints.prefix(8), id: \.self) { phrase in
                Text(phrase)
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.whatsubAccent.opacity(0.12),
                                in: Capsule())
                    .foregroundStyle(.whatsubAccent)
                    .lineLimit(1)
            }
        }
    }
}
