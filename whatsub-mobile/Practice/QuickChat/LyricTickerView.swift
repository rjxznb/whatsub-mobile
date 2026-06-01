import SwiftUI

/// Apple Music-style single-line lyric display. All words rendered dim;
/// the currently-spoken word lights up white. Auto-scrolls horizontally to
/// keep the active word centered. Glass material background.
struct LyricTickerView: View {
    var onTranslate: ((String) -> Void)? = nil
    var onReport: ((String) -> Void)? = nil

    @ObservedObject private var ticker = LyricTicker.shared

    var body: some View {
        Group {
            if ticker.currentSentence.isEmpty {
                Color.clear.frame(height: 56)   // Reserve space so layout doesn't jump.
            } else {
                lyricBubble
            }
        }
        .animation(.easeInOut(duration: 0.25), value: ticker.currentSentence)
    }

    private var lyricBubble: some View {
        let tokens = LyricTicker.tokenize(ticker.currentSentence)
        let activeRange = ticker.currentWordRange
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { idx, token in
                        wordView(text: token.text,
                                 isActive: isActive(token: token, active: activeRange),
                                 isPast: isPast(token: token, active: activeRange))
                            .id(idx)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
            .padding(.horizontal, 16)
            .onChange(of: activeRange) { newRange in
                guard let r = newRange else { return }
                guard let activeIdx = tokens.firstIndex(where: {
                    NSIntersectionRange($0.range, r).length > 0
                }) else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(activeIdx, anchor: .center)
                }
            }
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
        .frame(height: 56)
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
        Text(text)
            .font(.system(size: 19, weight: isActive ? .bold : .regular, design: .rounded))
            .foregroundStyle(
                isActive ? Color.white :
                    isPast ? Color.white.opacity(0.78) :
                    Color.white.opacity(0.32)
            )
            .scaleEffect(isActive ? 1.06 : 1.0)
            .shadow(color: isActive ? Color.white.opacity(0.6) : .clear,
                    radius: isActive ? 6 : 0)
            .animation(.easeInOut(duration: 0.18), value: isActive)
            .animation(.easeInOut(duration: 0.25), value: isPast)
    }
}
