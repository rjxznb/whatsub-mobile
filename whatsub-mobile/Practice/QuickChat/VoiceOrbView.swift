import SwiftUI

/// Audio-reactive orb. Two animation drivers:
/// - Breathing: state-based sin pulse, always running, gives the orb life
///   when idle/speaking/thinking/etc.
/// - Audio level: when caller passes a non-zero audioLevel (0..1), it adds
///   on top of breathing — orb grows, halo expands, blobs swing wider.
///   Color stays sapphire blue across all states (no red flip on recording).
///
/// Implementation: `TimelineView(.animation)` redraws ~30 fps. Every frame we
/// compute pulse, halo opacity, blob offsets, and rotation from time + the
/// current audioLevel. No `withAnimation` — direct value derivation is
/// smoother for amplitude-tracking.
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle, thinking, speaking, recording, transcribing
    }

    let state: OrbState
    var audioLevel: Float = 0    // 0..1, smoothed in VADCoordinator

    private let orbSize: CGFloat = 200
    private let haloSize: CGFloat = 290

    // Sparkle timing state — these use SwiftUI's withAnimation since they
    // twinkle independently and don't track audio.
    @State private var sparkle1: Double = 0
    @State private var sparkle2: Double = 0
    @State private var sparkle3: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let level = Double(audioLevel)
            let frame = computeFrame(time: now, level: level)

            ZStack {
                outerAura(scale: frame.pulse, opacity: frame.haloOpacity)
                ZStack {
                    innerGlow(driftA: frame.driftA, driftB: frame.driftB,
                              rotation: frame.rotation, amplitude: frame.driftAmplitude)
                    frostedGlass()
                    specularSheen()
                    rimStroke()
                }
                .frame(width: orbSize, height: orbSize)
                .scaleEffect(frame.pulse)
                .shadow(color: glowColor.opacity(0.4 + level * 0.3), radius: 20 + CGFloat(level * 10))
                sparkles
            }
            .frame(width: haloSize, height: haloSize)
        }
        .onAppear { startSparkles() }
    }

    // ---- frame derivation (pure function of time + level) ----

    private struct FrameValues {
        let pulse: CGFloat
        let haloOpacity: Double
        let driftA: Double           // drift angle for blob 1
        let driftB: Double           // drift angle for blob 2
        let driftAmplitude: Double   // how far blobs swing (px)
        let rotation: Double         // inner rotation (deg)
    }

    private func computeFrame(time: Double, level: Double) -> FrameValues {
        // Breathing pulse — always running, state-tuned.
        let bpPeriod = breathingPeriod
        let bpPeak = breathingPeak
        let phase = (sin(time * .pi * 2 / bpPeriod) + 1) / 2      // 0..1
        let breathPulse = 1.0 + phase * (bpPeak - 1.0)

        // Audio level adds on top — up to +0.28 scale for loud voice.
        let levelBoost = level * 0.28
        let pulse = breathPulse + levelBoost

        // Halo opacity — state base + level boost.
        let haloBase: Double = (state == .recording || state == .speaking) ? 0.58 : 0.45
        let haloOpacity = haloBase + level * 0.35

        // Blob drift — angle increments by time, amplitude expands with level.
        let driftBaseSpeed = blobBaseSpeed      // rad/sec at rest
        let driftSpeedMult = 1.0 + level * 1.5  // up to 2.5x faster swing
        let driftA = time * driftBaseSpeed * driftSpeedMult
        let driftB = time * driftBaseSpeed * driftSpeedMult * 1.4 + 2.1
        let driftAmplitude = 22.0 + level * 16.0  // px, base 22 → up to 38

        // Inner rotation — only meaningful on .thinking; otherwise very slow.
        let rotPeriod: Double = (state == .thinking) ? 4.5 : 22.0
        let rotation = (time.truncatingRemainder(dividingBy: rotPeriod)) / rotPeriod * 360

        return FrameValues(
            pulse: CGFloat(pulse),
            haloOpacity: haloOpacity,
            driftA: driftA,
            driftB: driftB,
            driftAmplitude: driftAmplitude,
            rotation: rotation
        )
    }

    private var breathingPeriod: Double {
        switch state {
        case .idle: return 3.2
        case .thinking: return 2.4
        case .speaking: return 1.3
        case .recording: return 1.6     // calmer breath — audio level adds the punch
        case .transcribing: return 0.6
        }
    }

    private var breathingPeak: Double {
        switch state {
        case .idle: return 1.05
        case .thinking: return 1.06
        case .speaking: return 1.16
        case .recording: return 1.04    // smaller breath; level does the work
        case .transcribing: return 1.10
        }
    }

    private var blobBaseSpeed: Double {
        switch state {
        case .idle: return 0.8
        case .thinking: return 1.0
        case .speaking: return 1.6
        case .recording: return 1.4
        case .transcribing: return 2.4
        }
    }

    // ---- layers ----

    private func outerAura(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(glowColor.opacity(opacity))
            .frame(width: haloSize, height: haloSize)
            .blur(radius: 55)
            .scaleEffect(scale * 1.0)
    }

    private func innerGlow(driftA: Double, driftB: Double, rotation: Double, amplitude: Double) -> some View {
        ZStack {
            glowBlob(color: glowColor,
                     size: 165,
                     offsetX: CGFloat(amplitude * cos(driftA)),
                     offsetY: CGFloat(amplitude * sin(driftA)),
                     blur: 30)
            glowBlob(color: accentColor,
                     size: 130,
                     offsetX: CGFloat(amplitude * cos(driftB)),
                     offsetY: CGFloat(amplitude * sin(driftB)),
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

    private func frostedGlass() -> some View {
        Circle()
            .fill(.ultraThinMaterial)
            .frame(width: orbSize, height: orbSize)
            .opacity(0.85)
    }

    private func specularSheen() -> some View {
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

    private func rimStroke() -> some View {
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

    // ---- sparkles (independent twinkle, not audio-driven) ----

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

    private func startSparkles() {
        sparkle1 = 0; sparkle2 = 0; sparkle3 = 0
        withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true).delay(0.0)) {
            sparkle1 = 0.85
        }
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true).delay(0.6)) {
            sparkle2 = 0.7
        }
        withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true).delay(0.3)) {
            sparkle3 = 0.55
        }
    }

    // ---- color palette: SAPPHIRE for all non-warm states; warm only for transcribing ----
    // NOTE: .recording deliberately uses the SAPPHIRE palette (no red) — user
    // wanted size/amplitude to communicate the listening state, not color.
    private var glowColor: Color {
        switch state {
        case .transcribing: return Color(red: 1.0, green: 0.72, blue: 0.18)
        default:            return Color(red: 0.20, green: 0.50, blue: 1.0)   // sapphire blue
        }
    }
    private var accentColor: Color {
        switch state {
        case .transcribing: return Color(red: 1.0, green: 0.92, blue: 0.55)
        default:            return Color(red: 0.45, green: 0.78, blue: 1.0)   // brighter cyan
        }
    }
}
