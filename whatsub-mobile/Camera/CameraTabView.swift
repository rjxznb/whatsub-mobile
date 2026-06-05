import SwiftUI

/// 「实景口语练习」tab — the third TabView slot. The body IS the
/// `LiveSceneView` flow (picker → Vision → LLM prompt → speak →
/// graded) so the primary feature is one tap deep, not two.
///
/// Secondary feature 「拍照翻译」 sits as a top-right toolbar button on
/// the custom header (sheet-presented like before). Two related camera
/// surfaces, one tab — primary inline, secondary one tap away.
///
/// 2026-06-05 (was a card-list shell at first; flattened per design ask).
struct CameraTabView: View {
    @State private var showPhotoTranslate = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Custom header: title left, 拍照翻译 icon right. Same
                // pattern Library uses (its "+" button on the right) so
                // the two camera-adjacent surfaces feel structurally
                // consistent. System nav bar stays hidden so the layout
                // matches Library / 语料库 / 我的.
                HStack(alignment: .firstTextBaseline) {
                    Text("实景口语练习")
                        // 26pt vs the 34pt used elsewhere — the title is
                        // 6 chars (vs 2-3 for "我的" / "语料库" / "Library")
                        // and would overflow on small phones at 34. Still
                        // larger than a body font so the header presence
                        // is preserved.
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.whatsubInk)
                    Spacer()
                    Button {
                        showPhotoTranslate = true
                    } label: {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.whatsubAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("拍照翻译")
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)

                LiveSceneView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.whatsubBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPhotoTranslate) {
                PhotoReviewView()
            }
        }
    }
}
