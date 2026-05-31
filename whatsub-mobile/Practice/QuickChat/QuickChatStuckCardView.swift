import SwiftUI

/// Popup card shown when the user taps an un-completed phrase chip — the
/// "复习救生索" of spec §6.5. Always shows the text-only review (contextSentence
/// + meaningZh + usageNote). If the phrase came from a YouTube clip, an
/// extra "▶ 看原片那一句" jumps to it (requires VPN; user has VPN if they had
/// it for the original clip viewing).
struct QuickChatStuckCardView: View {
    let phrase: SessionPhrase
    let onPlayOriginal: (() -> Void)?     // nil = no YouTube/timestamp available
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(phrase.phraseRaw)
                    .font(.headline.weight(.bold)).foregroundStyle(.whatsubInk)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                        .foregroundStyle(.whatsubInkFaint)
                }
            }
            if let meaning = phrase.meaningZh, !meaning.isEmpty {
                Text(meaning).font(.subheadline).foregroundStyle(.whatsubAccent)
            }
            if let usage = phrase.usageNote, !usage.isEmpty {
                Text(usage).font(.footnote).foregroundStyle(.whatsubInkMuted)
            }
            Divider().opacity(0.4)
            Text("当初收藏的那句：").font(.caption).foregroundStyle(.whatsubInkFaint)
            Text(phrase.contextSentence)
                .font(.system(size: 16))
                .foregroundStyle(.whatsubInk)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBg))
            if let play = onPlayOriginal {
                Button(action: play) {
                    Label("▶ 看原片那一句", systemImage: "play.rectangle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered).tint(.whatsubAccent)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.whatsubBgElev))
        .padding(.horizontal, 16)
    }
}
