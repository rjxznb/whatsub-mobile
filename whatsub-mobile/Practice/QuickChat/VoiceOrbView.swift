import SwiftUI

/// "Heart of the Ocean" sapphire-style orb. Reverse of the prior frosted-glass
/// approach: deep dark core radiating out to a bright rim, sharp specular
/// highlight (not soft), rim light on the opposite side, subtle sparkle glints
/// that fade in and out independently.
///
/// Layers:
///   1. Outer halo — colored glow, blurred
///   2. Inner facet plane — slowly rotating angular highlights INSIDE the orb,
///      simulating internal reflections from cut facets
///   3. Gemstone body — radial gradient deep core → mid → bright rim
///   4. Specular highlight — small sharp white spot upper-left
///   5. Edge rim light — bright crescent on bottom-right
///   6. Outer ring stroke — gem-edge bright outline
///   7. Sparkle dots — 3 tiny white dots fading in/out (the "diamond setting")
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle
        case thinking
        case speaking
        case recording
        case transcribing
    }

    let state: OrbState

    @State private var pulse: CGFloat = 1.0
    @State private var rotation: Double = 0
    @State private var glowOpacity: Double = 0.5
    @State private var sparkle1: Double = 0
    @State private var sparkle2: Double = 0
    @State private var sparkle3: Double = 0

    private let orbSize: CGFloat = 200
    private let haloSize: CGFloat = 280

    var body: some View {
        ZStack {
            outerHalo
            ZStack {
                facetPlane
                gemstoneBody
                specularHighlight
                rimLight
                edgeRing
            }
            .frame(width: orbSize, height: orbSize)
            .scaleEffect(pulse)
            .shadow(color: coreColor.opacity(0.7), radius: 30, x: 0, y: 4)
            sparkles
        }
        .frame(width: haloSize, height: haloSize)
        .onAppear { startAnimations(for: state) }
        .onChange(of: state) { applyAnimations(for: $0) }
    }

    // ---- layer 1: outer halo ----
    private var outerHalo: some View {
        Circle()
            .fill(coreColor.opacity(glowOpacity))
            .frame(width: haloSize, height: haloSize)
            .blur(radius: 50)
            .scaleEffect(pulse)
    }

    // ---- layer 2: internal facet plane (rotating angular highlights) ----
    private var facetPlane: some View {
        ZStack {
            facetStreak(opacity: 0.30, width: 50, height: 110, rotation: 35,
                        offsetX: -22, offsetY: -28)
            facetStreak(opacity: 0.22, width: 45, height: 90, rotation: -40,
                        offsetX: 28, offsetY: 18)
            facetStreak(opacity: 0.18, width: 30, height: 70, rotation: 75,
                        offsetX: -5, offsetY: 35)
        }
        .rotationEffect(.degrees(rotation))
        .clipShape(Circle())
        .frame(width: orbSize, height: orbSize)
    }

    private func facetStreak(opacity: Double, width: CGFloat, height: CGFloat,
                             rotation: Double, offsetX: CGFloat, offsetY: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(
                    colors: [.white.opacity(opacity), rimColor.opacity(opacity * 0.6), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: width, height: height)
            .rotationEffect(.degrees(rotation))
            .offset(x: offsetX, y: offsetY)
            .blur(radius: 5)
            .blendMode(.plusLighter)
    }

    // ---- layer 3: gemstone body (deep core → bright rim) ----
    private var gemstoneBody: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        deepCoreColor,   // very dark navy/red/amber at very center
                        coreColor,       // saturated mid layer
                        rimColor         // bright outer edge
                    ],
                    center: .center,
                    startRadius: 5,
                    endRadius: orbSize / 2
                )
            )
            .frame(width: orbSize, height: orbSize)
    }

    // ---- layer 4: sharp specular (small hard highlight) ----
    private var specularHighlight: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.85), .white.opacity(0.2), .clear],
                    center: UnitPoint(x: 0.32, y: 0.27),
                    startRadius: 1, endRadius: 28
                )
            )
            .frame(width: orbSize, height: orbSize)
            .blendMode(.plusLighter)
    }

    // ---- layer 5: rim light (bright crescent bottom-right) ----
    private var rimLight: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.clear, .clear, rimColor.opacity(0.7), .white.opacity(0.5)],
                    center: UnitPoint(x: 0.78, y: 0.82),
                    startRadius: 60, endRadius: 105
                )
            )
            .frame(width: orbSize, height: orbSize)
            .blendMode(.plusLighter)
    }

    // ---- layer 6: edge ring (gem-edge outline) ----
    private var edgeRing: some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(0.55),
                        rimColor.opacity(0.85),
                        .white.opacity(0.25),
                        rimColor.opacity(0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.5
            )
            .frame(width: orbSize, height: orbSize)
    }

    // ---- layer 7: sparkle dots ----
    private var sparkles: some View {
        ZStack {
            sparkleDot(offsetX: -55, offsetY: -68, opacity: sparkle1)
            sparkleDot(offsetX: 62, offsetY: -42, opacity: sparkle2)
            sparkleDot(offsetX: -32, offsetY: 72, opacity: sparkle3)
        }
        .frame(width: haloSize, height: haloSize)
    }

    private func sparkleDot(offsetX: CGFloat, offsetY: CGFloat, opacity: Double) -> some View {
        ZStack {
            // Outer glow.
            Circle().fill(.white.opacity(0.4)).frame(width: 10, height: 10).blur(radius: 4)
            // Hard dot.
            Circle().fill(.white).frame(width: 3, height: 3)
        }
        .opacity(opacity)
        .offset(x: offsetX, y: offsetY)
    }

    // ---- color palette per state ----
    private var deepCoreColor: Color {
        switch state {
        case .recording:    return Color(red: 0.22, green: 0.02, blue: 0.06)   // dark ruby
        case .transcribing: return Color(red: 0.30, green: 0.16, blue: 0.02)   // dark topaz
        default:            return Color(red: 0.02, green: 0.05, blue: 0.18)   // dark navy (sapphire)
        }
    }
    private var coreColor: Color {
        switch state {
        case .recording:    return Color(red: 0.85, green: 0.12, blue: 0.20)
        case .transcribing: return Color(red: 1.00, green: 0.62, blue: 0.10)
        default:            return Color(red: 0.10, green: 0.28, blue: 0.85)   // sapphire blue
        }
    }
    private var rimColor: Color {
        switch state {
        case .recording:    return Color(red: 1.00, green: 0.40, blue: 0.55)
        case .transcribing: return Color(red: 1.00, green: 0.90, blue: 0.50)
        default:            return Color(red: 0.40, green: 0.70, blue: 1.00)   // electric cerulean
        }
    }

    // ---- animation driver ----
    private func startAnimations(for s: OrbState) {
        applyAnimations(for: s)
    }

    private func applyAnimations(for s: OrbState) {
        // Pulse (scale + halo)
        let (peak, period): (CGFloat, Double)
        switch s {
        case .idle:         (peak, period) = (1.04, 3.2)
        case .thinking:     (peak, period) = (1.05, 2.4)
        case .speaking:     (peak, period) = (1.12, 1.4)
        case .recording:    (peak, period) = (1.14, 0.9)
        case .transcribing: (peak, period) = (1.08, 0.6)
        }
        pulse = 1.0
        glowOpacity = 0.45
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            pulse = peak
            glowOpacity = s == .recording ? 0.7 : 0.55
        }

        // Internal facet rotation — slow always, faster on .thinking.
        rotation = 0
        let rotPeriod: Double = s == .thinking ? 5.5 : 22.0
        withAnimation(.linear(duration: rotPeriod).repeatForever(autoreverses: false)) {
            rotation = 360
        }

        // Sparkles — each blinks at different period + delay so they twinkle out of phase.
        sparkle1 = 0; sparkle2 = 0; sparkle3 = 0
        withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true).delay(0.0)) {
            sparkle1 = 0.85
        }
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true).delay(0.6)) {
            sparkle2 = 0.7
        }
        withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true).delay(0.3)) {
            sparkle3 = 0.6
        }
    }
}
