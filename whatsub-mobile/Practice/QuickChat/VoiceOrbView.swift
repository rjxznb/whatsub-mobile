import SwiftUI

/// Central 豆包/Siri-style animated orb. Pure visual — driven by a state
/// enum the parent passes in. No audio coupling (deliberately simple — we
/// can wire real audio reactivity later if needed).
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle
        case thinking         // rotating
        case speaking         // blue breathing
        case recording        // red faster
        case transcribing     // small fast pulse
    }

    let state: OrbState

    @State private var pulse: CGFloat = 1.0
    @State private var rotation: Double = 0
    @State private var glowOpacity: Double = 0.45

    var body: some View {
        ZStack {
            // Outer halo — soft glow, larger, animates opacity with pulse.
            Circle()
                .fill(orbColor.opacity(glowOpacity))
                .frame(width: 260, height: 260)
                .blur(radius: 40)
                .scaleEffect(pulse)
            // Inner orb — gradient sphere.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [orbColor.opacity(0.95), orbColor.opacity(0.55), orbColor.opacity(0.25)],
                        center: .center, startRadius: 10, endRadius: 110
                    )
                )
                .frame(width: 200, height: 200)
                .scaleEffect(pulse)
                .rotationEffect(.degrees(rotation))
                .overlay(
                    // Highlight to add depth.
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.35), .clear],
                                center: UnitPoint(x: 0.35, y: 0.3),
                                startRadius: 1, endRadius: 80
                            )
                        )
                        .frame(width: 200, height: 200)
                )
                .shadow(color: orbColor.opacity(0.6), radius: 30, x: 0, y: 0)
        }
        .frame(width: 280, height: 280)
        .onAppear { applyAnimation(for: state) }
        .onChange(of: state) { newState in applyAnimation(for: newState) }
    }

    // ---- state-driven animation ----

    private var orbColor: Color {
        switch state {
        case .recording: return .red
        case .speaking, .transcribing: return Color.whatsubAccent
        case .thinking: return Color.whatsubAccent.opacity(0.7)
        case .idle: return Color.whatsubAccent.opacity(0.6)
        }
    }

    private func applyAnimation(for s: OrbState) {
        // Reset to base then start the matching animation.
        // We use distinct withAnimation blocks so the system can cancel + retarget.
        withAnimation(.easeInOut(duration: 0.25)) {
            // Pull values back to mid-state before re-targeting.
            // (Not strictly needed, but smooths the transition.)
        }
        // Pulse / scale
        let (peak, period): (CGFloat, Double)
        switch s {
        case .idle:         (peak, period) = (1.05, 3.0)
        case .thinking:     (peak, period) = (1.04, 2.0)
        case .speaking:     (peak, period) = (1.18, 1.2)
        case .recording:    (peak, period) = (1.18, 0.8)
        case .transcribing: (peak, period) = (1.10, 0.5)
        }
        // Reset to 1.0 instantly so the repeatForever cycle is symmetric.
        pulse = 1.0
        glowOpacity = 0.45
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            pulse = peak
            glowOpacity = s == .recording ? 0.65 : 0.55
        }
        // Rotation: only on .thinking.
        rotation = 0
        if s == .thinking {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
