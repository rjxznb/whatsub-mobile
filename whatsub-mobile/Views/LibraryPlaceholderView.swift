import SwiftUI

struct LibraryPlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 56))
                    .foregroundStyle(.whatsubAccent)
                Text("Library")
                    .font(.title2.weight(.semibold))
                Text("桌面同步 YouTube 字幕\nPhase 2 加上线")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .navigationTitle("Library")
        }
    }
}

#Preview { LibraryPlaceholderView() }
