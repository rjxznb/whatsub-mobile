import SwiftUI

/// Siri-style frosted-glass orb. Three layers stacked:
///
/// 1. Outer halo — soft colored glow, blurred, scales with pulse.
/// 2. Color blob layer — 3 blurred colored circles drifting/rotating
///    behind the glass; gives the iridescent swirl (this is what Siri does).
/// 3. Frosted glass surface — `.ultraThinMaterial` clipped to circle,
///    with thin rim highlight, top-left specular sheen, bottom-right
///    shadow for depth.
///
/// Pure visual. Driven by an `OrbState` the parent passes in. The blob
/// drift animates continuously; pulse + halo speed varies by state.
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle
        case thinking         // slow rotation, gentle pulse
        case speaking         // medium blue-cyan pulse
        case recording        // fast red-orange pulse
        case transcribing     // fast yellow shimmer
    }

    let state: OrbState

    // Animated state
    @State private var pulse: CGFloat = 1.0
    @State private var rotation: Double = 0
    @State private var blobDrift: Double = 0
    @State private var glowOpacity: Double = 0.45

    private let orbSize: CGFloat = 200
    private let haloSize: CGFloat = 280

    var body: some View {
        ZStack {
            outerHalo
            glassOrb
        }
        .frame(width: haloSize, height: haloSize)
        .onAppear { startAnimations(for: state) }
        .onChange(of: state) { newState in startAnimations(for: newState) }
    }

    // ---- layer 1: outer halo (soft colored glow) ----
    private var outerHalo: some View {
        Circle()
            .fill(palette.primary.opacity(glowOpacity))
            .frame(width: haloSize, height: haloSize)
            .blur(radius: 50)
            .scaleEffect(pulse)
    }

    // ---- layers 2 + 3: the glass orb itself ----
    private var glassOrb: some View {
        ZStack {
            // Layer 2 — colorful drifting blobs (the iridescence)
            blobLayer
            // Layer 3 — frosted glass surface + specular detail
            glassSurface
        }
        .frame(width: orbSize, height: orbSize)
        .scaleEffect(pulse)
        .shadow(color: palette.primary.opacity(0.5), radius: 28, x: 0, y: 4)
    }

    // ---- blob layer (3 blurred circles, drifting + rotating) ----
    private var blobLayer: some View {
        ZStack {
            blob(color: palette.primary,
                 size: 170,
                 offsetX: 24 * cos(blobDrift * 1.0),
                 offsetY: 22 * sin(blobDrift * 1.0),
                 blurRadius: 32)
            blob(color: palette.secondary,
                 size: 140,
                 offsetX: 28 * cos(blobDrift * 1.4 + 2.1),
                 offsetY: 26 * sin(blobDrift * 1.4 + 2.1),
                 blurRadius: 28)
            blob(color: palette.accent,
                 size: 120,
                 offsetX: 22 * cos(blobDrift * 1.8 + 4.2),
                 offsetY: 24 * sin(blobDrift * 1.8 + 4.2),
                 blurRadius: 24)
        }
        .frame(width: orbSize, height: orbSize)
        .clipShape(Circle())
        .rotationEffect(.degrees(rotation))
    }

    private func blob(color: Color, size: CGFloat,
                      offsetX: CGFloat, offsetY: CGFloat, blurRadius: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.95), color.opacity(0.55), color.opacity(0.0)],
                    center: .center, startRadius: 1, endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .offset(x: offsetX, y: offsetY)
            .blur(radius: blurRadius)
    }

    // ---- glass surface (frosted material + rim + highlight + shadow) ----
    private var glassSurface: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                // Rim — thin bright stroke around the edge for the glass-edge specular.
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.6), .white.opacity(0.05), .white.opacity(0.0), .white.opacity(0.25)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            )
            .overlay(
                // Top-left sheen — concentrated bright highlight, glass-like.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.08), .clear],
                            center: UnitPoint(x: 0.3, y: 0.25),
                            startRadius: 1, endRadius: 80
                        )
                    )
                    .blendMode(.plusLighter)
            )
            .overlay(
                // Bottom-right shadow — gives depth, suggests light coming from upper-left.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.clear, .black.opacity(0.22)],
                            center: UnitPoint(x: 0.78, y: 0.82),
                            startRadius: 30, endRadius: 110
                        )
                    )
            )
            .frame(width: orbSize, height: orbSize)
    }

    // ---- per-state color palette ----
    private struct Palette {
        let primary: Color
        let secondary: Color
        let accent: Color
    }

    private var palette: Palette {
        switch state {
        case .recording:
            // Hot palette — red + orange + pink. Reads as "alert/listening".
            return Palette(
                primary: Color(red: 1.0, green: 0.30, blue: 0.35),
                secondary: Color(red: 1.0, green: 0.55, blue: 0.30),
                accent: Color(red: 0.95, green: 0.40, blue: 0.65)
            )
        case .transcribing:
            // Warm yellow shimmer with brand-yellow accent.
            return Palette(
                primary: Color(red: 1.00, green: 0.83, blue: 0.27), // brand yellow #FCD34D
                secondary: Color(red: 1.00, green: 0.62, blue: 0.20),
                accent: Color(red: 0.96, green: 0.95, blue: 0.66)
            )
        case .speaking, .thinking, .idle:
            // Cool palette — blue + cyan + violet. Brand-aligned (whatsubAccent dominant).
            return Palette(
                primary: Color(red: 0.23, green: 0.61, blue: 1.00), // whatsubAccent ~#3B9BFF
                secondary: Color(red: 0.30, green: 0.85, blue: 0.95),
                accent: Color(red: 0.55, green: 0.45, blue: 0.95)
            )
        }
    }

    // ---- animation driver ----
    private func startAnimations(for s: OrbState) {
        // 1. Pulse — scale 1.0 ↔ peak with a sin-like ease, repeating.
        let (peak, period): (CGFloat, Double)
        switch s {
        case .idle:         (peak, period) = (1.05, 3.2)
        case .thinking:     (peak, period) = (1.06, 2.4)
        case .speaking:     (peak, period) = (1.15, 1.3)
        case .recording:    (peak, period) = (1.18, 0.8)
        case .transcribing: (peak, period) = (1.10, 0.55)
        }
        pulse = 1.0
        glowOpacity = 0.40
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            pulse = peak
            glowOpacity = (s == .recording) ? 0.7 : 0.6
        }

        // 2. Rotation — only meaningful on .thinking (slow spin makes blobs swirl).
        //    Other states: very slow drift rotation so glass never looks frozen.
        rotation = 0
        let rotationPeriod: Double = (s == .thinking) ? 4.0 : 20.0
        withAnimation(.linear(duration: rotationPeriod).repeatForever(autoreverses: false)) {
            rotation = 360
        }

        // 3. Blob drift — independent parametric motion so the blobs never line
        //    up the same way twice. Faster for active states.
        blobDrift = 0
        let driftPeriod: Double = {
            switch s {
            case .idle: return 8.0
            case .thinking: return 5.0
            case .speaking: return 3.5
            case .recording: return 2.0
            case .transcribing: return 1.6
            }
        }()
        withAnimation(.linear(duration: driftPeriod).repeatForever(autoreverses: false)) {
            blobDrift = .pi * 2
        }
    }
}
