import SwiftUI

/// Apple Music-style lyric display. Big bold text, natural multi-line wrap,
/// no background card. Each word transitions from dim (~35% opacity) to
/// bright white as TTS plays it. Past words stay slightly faded; upcoming
/// words start dim.
///
/// Sized to fit ~3 lines of large text. Words are individually rendered so
/// per-word opacity / weight transitions are animatable.
struct LyricTickerView: View {
    var onTranslate: ((String) -> Void)? = nil
    var onReport: ((String) -> Void)? = nil

    @ObservedObject private var ticker = LyricTicker.shared

    /// Apple Music uses ~30-34pt for the active line. Smaller looks weak;
    /// bigger overflows on iPhone SE. 28pt is a good middle ground.
    private let fontSize: CGFloat = 28
    /// Reserve a visual area for ~3 lines so layout doesn't jump when text
    /// arrives. height = fontSize × ~1.35 line height × 3 = ~113pt.
    private let reservedHeight: CGFloat = 120

    var body: some View {
        Group {
            if ticker.currentSentence.isEmpty {
                Color.clear.frame(height: reservedHeight)
            } else {
                lyricsBlock
                    .frame(maxWidth: .infinity, minHeight: reservedHeight, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.30), value: ticker.currentSentence)
    }

    private var lyricsBlock: some View {
        let tokens = LyricTicker.tokenize(ticker.currentSentence)
        let activeRange = ticker.currentWordRange
        return FlowLayout(spacing: 8, lineSpacing: 6) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                wordView(
                    text: token.text,
                    isActive: isActive(token: token, active: activeRange),
                    isPast: isPast(token: token, active: activeRange)
                )
            }
        }
        .padding(.horizontal, 22)
        .contextMenu {
            if let onTranslate {
                Button {
                    onTranslate(ticker.currentSentence)
                } label: { Label("显示中文", systemImage: "character.bubble") }
            }
            if let onReport {
                Button {
                    onReport(ticker.currentSentence)
                } label: { Label("上报这条回复", systemImage: "exclamationmark.bubble") }
            }
        }
    }

    private func isActive(token: LyricTicker.Token, active: NSRange?) -> Bool {
        guard let active else { return false }
        return NSIntersectionRange(token.range, active).length > 0
    }

    private func isPast(token: LyricTicker.Token, active: NSRange?) -> Bool {
        guard let active else { return false }
        return token.range.location + token.range.length <= active.location
    }

    @ViewBuilder
    private func wordView(text: String, isActive: Bool, isPast: Bool) -> some View {
        // Apple Music style: bold all the time, never resized. The transition
        // is only color/opacity — keeps the layout perfectly stable so words
        // don't shift around when the next one activates.
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(
                isActive ? Color.white :
                    isPast ? Color.white.opacity(0.80) :
                    Color.white.opacity(0.32)
            )
            .animation(.easeInOut(duration: 0.22), value: isActive)
            .animation(.easeInOut(duration: 0.30), value: isPast)
    }
}
