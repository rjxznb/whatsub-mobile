import SwiftUI

/// 「眼前」tab — unified surface for "real world → English" inputs:
/// camera-based learning (拍照翻译, 实景口语练习) + a soft pointer to the
/// Share Extension import path (from YouTube / Bilibili apps).
///
/// Why a dedicated tab vs. another entry buried under 我的→工具:
///   - These features are about USING the phone camera to learn —
///     a distinct mode of interaction from "watch a video in Library"
///     or "review phrases in 语料库".
///   - 导入视频 moved out of 我的 too (now a "+" button on Library) so
///     工具 stays small + means "settings / maintenance" only.
///   - Tab name 「眼前」 (in front of your eyes) — emphasises the
///     "use what's right around you" framing the camera + share
///     surfaces share.
///
/// 2026-06-05.
struct CameraTabView: View {
    @State private var showPhoto = false
    @State private var showLiveScene = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Custom large title — same pattern Library / 语料库 / 我的
                // use; the system large title doesn't play well with our
                // global UINavigationBarAppearance + tab bar combo.
                Text("眼前")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.whatsubInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 14) {
                        featureCard(
                            title: "实景口语练习",
                            subtitle: "拍下你眼前的场景,AI 给你出口语题 → 说 → 打分 + 标准答案",
                            // Custom multi-color SVG (asset catalog,
                            // template-rendering-intent: original) — see
                            // featureCard(...isCustomAsset) signature
                            // below; we branch on whether to render via
                            // Image("name") or Image(systemName:).
                            icon: "LiveSceneCardIcon",
                            isCustomAsset: true,
                            action: { showLiveScene = true }
                        )
                        featureCard(
                            title: "拍照翻译",
                            subtitle: "对一段英文拍照,AI 翻译全文 + 提取重点短语,挑选加入语料库",
                            icon: "camera.viewfinder",
                            action: { showPhoto = true }
                        )
                        importHint
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.whatsubBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPhoto) {
                PhotoReviewView()
            }
            .sheet(isPresented: $showLiveScene) {
                LiveSceneView()
            }
        }
    }

    // MARK: - icon helper

    /// Branch between SF Symbol and custom asset rendering. Kept separate
    /// from `featureCard` so the size/styling decisions stay in one place
    /// (any future cards picking a custom asset reuse it).
    @ViewBuilder
    private func iconView(name: String, isCustomAsset: Bool) -> some View {
        if isCustomAsset {
            Image(name)
                .resizable()
                .renderingMode(.original)   // keep the SVG's brand palette
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: name)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.whatsubAccent)
        }
    }

    // MARK: - feature card

    /// `isCustomAsset` switches the icon rendering path:
    ///   - false (default) → SF Symbol via `Image(systemName:)`, tinted
    ///     `.whatsubAccent`, font-sized 28pt.
    ///   - true → custom asset via `Image(_:)` with `.renderingMode(.original)`
    ///     so the multi-color SVG (e.g. 风景) keeps its own brand-aligned
    ///     palette. Resized to the same 36×36 box as the SF Symbol path
    ///     so the two card icons line up visually.
    private func featureCard(
        title: String,
        subtitle: String,
        icon: String,
        isCustomAsset: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                iconView(name: icon, isCustomAsset: isCustomAsset)
                    .frame(width: 36, height: 36, alignment: .center)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.whatsubInk)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.whatsubInkFaint)
            }
            .padding(16)
            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - share-from-other-apps hint

    /// Quieter card at the bottom — informational not interactive (no
    /// chevron; no tap). Surfaces the existence of the Share Extension
    /// for users who don't realise they can push YouTube/Bilibili URLs
    /// into whatSub from those apps.
    private var importHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.whatsubInkMuted)
                Text("也可以分享视频进来")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.whatsubInkMuted)
            }
            Text("在 YouTube 或 B 站 app 里点 分享 → whatSub,视频会自动进入「我的视频库」。")
                .font(.caption)
                .foregroundStyle(.whatsubInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.whatsubBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.whatsubBgElev, lineWidth: 1)
        )
        .padding(.top, 10)
    }
}
