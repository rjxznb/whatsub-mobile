import SwiftUI

struct ManagedAnalysisSparklePresentation: Equatable {
    let shouldAnimate: Bool
    let restingScale: CGFloat
    let expandedScale: CGFloat
    let restingOpacity: Double
    let expandedOpacity: Double

    init(isPolling: Bool, reduceMotion: Bool) {
        shouldAnimate = isPolling && !reduceMotion
        if shouldAnimate {
            restingScale = 0.92
            expandedScale = 1.10
            restingOpacity = 0.55
            expandedOpacity = 1.0
        } else {
            restingScale = 1.0
            expandedScale = 1.0
            restingOpacity = 1.0
            expandedOpacity = 1.0
        }
    }
}

struct ManagedAnalysisSparkleIcon: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var presentation: ManagedAnalysisSparklePresentation {
        .init(isPolling: isActive, reduceMotion: reduceMotion)
    }

    var body: some View {
        Image(systemName: "sparkles")
            .scaleEffect(expanded ? presentation.expandedScale : presentation.restingScale)
            .opacity(expanded ? presentation.expandedOpacity : presentation.restingOpacity)
            .animation(
                presentation.shouldAnimate
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: expanded
            )
            .onAppear(perform: updateAnimation)
            .onChange(of: isActive) { _ in updateAnimation() }
            .onChange(of: reduceMotion) { _ in updateAnimation() }
    }

    private func updateAnimation() {
        expanded = presentation.shouldAnimate
    }
}
