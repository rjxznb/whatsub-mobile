import SwiftUI

/// Hybrid orb: sapphire glow inner halo + frosted-glass surface + soft outer
/// aura. Combines transparency (no plasticky opaque body) with the deep blue
/// jewel color the Heart-of-Ocean variant had.
///
/// Layers, back to front:
/// 1. Outer aura — large blurred colored circle, scales with pulse
/// 2. Inner glow blobs — 2 colored blobs drifting/rotating, blurred,
///    clipped to the orb circle (these provide the "sapphire heart" tint
///    through the glass)
/// 3. Frosted glass surface — `.ultraThinMaterial` clipped to circle
/// 4. Specular sheen — soft top-left bright highlight
/// 5. Subtle rim stroke — thin gradient outline
/// 6. Sparkle dots — 3 tiny twinkling lights outside the orb (gem setting)
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle, thinking, speaking, recording, transcribing
    }

    let state: OrbState

    @State private var pulse: CGFloat = 1.0
    @State private var rotation: Double = 0
    @State private var glowOpacity: Double = 0.55
    @State private var blobDrift: Double = 0
    @State private var sparkle1: Double = 0
    @State private var sparkle2: Double = 0
    @State private var sparkle3: Double = 0

    private let orbSize: CGFloat = 200
    private let haloSize: CGFloat = 290

    var body: some View {
        ZStack {
            outerAura
            ZStack {
                innerGlow
                frostedGlass
                specularSheen
                rimStroke
            }
            .frame(width: orbSize, height: orbSize)
            .scaleEffect(pulse)
            .shadow(color: glowColor.opacity(0.5), radius: 24)
            sparkles
        }
        .frame(width: haloSize, height: haloSize)
        .onAppear { applyAnimations(for: state) }
        .onChange(of: state) { applyAnimations(for: $0) }
    }

    // Layer 1 — outer aura
    private var outerAura: some View {
        Circle()
            .fill(glowColor.opacity(glowOpacity))
            .frame(width: haloSize, height: haloSize)
            .blur(radius: 55)
            .scaleEffect(pulse)
    }

    // Layer 2 — inner glow blobs (the colored "heart" visible through the glass)
    private var innerGlow: some View {
        ZStack {
            glowBlob(color: glowColor,
                     size: 165,
                     offsetX: 22 * cos(blobDrift),
                     offsetY: 22 * sin(blobDrift),
                     blur: 30)
            glowBlob(color: accentColor,
                     size: 130,
                     offsetX: 24 * cos(blobDrift * 1.5 + 2.1),
                     offsetY: 24 * sin(blobDrift * 1.5 + 2.1),
                     blur: 26)
        }
        .frame(width: orbSize, height: orbSize)
        .clipShape(Circle())
        .rotationEffect(.degrees(rotation))
    }

    private func glowBlob(color: Color, size: CGFloat,
                          offsetX: CGFloat, offsetY: CGFloat, blur: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.95), color.opacity(0.5), color.opacity(0.0)],
                    center: .center, startRadius: 1, endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .offset(x: offsetX, y: offsetY)
            .blur(radius: blur)
    }

    // Layer 3 — frosted glass (the actual translucent surface)
    private var frostedGlass: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .frame(width: orbSize, height: orbSize)
            .opacity(0.85)   // slightly less than full opaque material so the inner glow shows through
    }

    // Layer 4 — soft specular sheen (not a hard plastic highlight)
    private var specularSheen: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.35), .white.opacity(0.05), .clear],
                    center: UnitPoint(x: 0.32, y: 0.27),
                    startRadius: 1, endRadius: 70
                )
            )
            .frame(width: orbSize, height: orbSize)
            .blendMode(.plusLighter)
    }

    // Layer 5 — subtle rim stroke
    private var rimStroke: some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.4), .white.opacity(0.05), .clear, accentColor.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
            .frame(width: orbSize, height: orbSize)
    }

    // Layer 6 — sparkles (gem setting diamonds)
    private var sparkles: some View {
        ZStack {
            sparkleDot(offsetX: -58, offsetY: -72, opacity: sparkle1)
            sparkleDot(offsetX: 64, offsetY: -45, opacity: sparkle2)
            sparkleDot(offsetX: -28, offsetY: 78, opacity: sparkle3)
        }
        .frame(width: haloSize, height: haloSize)
    }

    private func sparkleDot(offsetX: CGFloat, offsetY: CGFloat, opacity: Double) -> some View {
        ZStack {
            Circle().fill(.white.opacity(0.35)).frame(width: 10, height: 10).blur(radius: 4)
            Circle().fill(.white).frame(width: 3, height: 3)
        }
        .opacity(opacity)
        .offset(x: offsetX, y: offsetY)
    }

    // ---- color palette per state ----
    private var glowColor: Color {
        switch state {
        case .recording:    return Color(red: 1.0, green: 0.30, blue: 0.40)
        case .transcribing: return Color(red: 1.0, green: 0.72, blue: 0.18)
        default:            return Color(red: 0.20, green: 0.50, blue: 1.0)   // sapphire blue
        }
    }
    private var accentColor: Color {
        switch state {
        case .recording:    return Color(red: 1.0, green: 0.55, blue: 0.30)
        case .transcribing: return Color(red: 1.0, green: 0.92, blue: 0.55)
        default:            return Color(red: 0.45, green: 0.78, blue: 1.0)   // brighter cyan
        }
    }

    // ---- animation driver ----
    private func applyAnimations(for s: OrbState) {
        let (peak, period): (CGFloat, Double)
        switch s {
        case .idle:         (peak, period) = (1.05, 3.2)
        case .thinking:     (peak, period) = (1.06, 2.4)
        case .speaking:     (peak, period) = (1.16, 1.3)
        case .recording:    (peak, period) = (1.16, 0.85)
        case .transcribing: (peak, period) = (1.10, 0.55)
        }
        pulse = 1.0; glowOpacity = 0.45
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            pulse = peak
            glowOpacity = s == .recording ? 0.7 : 0.6
        }

        rotation = 0
        let rotPeriod: Double = s == .thinking ? 4.5 : 22.0
        withAnimation(.linear(duration: rotPeriod).repeatForever(autoreverses: false)) {
            rotation = 360
        }

        blobDrift = 0
        let driftPeriod: Double = {
            switch s {
            case .idle: return 8
            case .thinking: return 5
            case .speaking: return 3.5
            case .recording: return 2
            case .transcribing: return 1.5
            }
        }()
        withAnimation(.linear(duration: driftPeriod).repeatForever(autoreverses: false)) {
            blobDrift = .pi * 2
        }

        sparkle1 = 0; sparkle2 = 0; sparkle3 = 0
        withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true).delay(0.0)) { sparkle1 = 0.85 }
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true).delay(0.6)) { sparkle2 = 0.7 }
        withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true).delay(0.3)) { sparkle3 = 0.55 }
    }
}
