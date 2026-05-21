import SwiftUI

struct CorpusPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 56))
                        .foregroundStyle(.whatsubAccent)
                    Text("语料库")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.whatsubInk)
                    Text("公共 + 我的语料库浏览\nPhase 2 加上线")
                        .font(.callout)
                        .foregroundStyle(.whatsubInkMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .navigationTitle("语料库")
        }
    }
}

#Preview { CorpusPlaceholderView() }
