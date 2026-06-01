import SwiftUI

/// Audio-reactive orb. Continuous TimelineView at 60fps. Blob drift uses a
/// phase accumulator (not time × speed) so when speed changes the angle stays
/// continuous — no visual teleportation.
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle, thinking, speaking, recording, transcribing
    }

    let state: OrbState
    var audioLevel: Float = 0    // 0..1, smoothed in VADCoordinator

    private let orbSize: CGFloat = 200
    private let haloSize: CGFloat = 290

    @State private var sparkle1: Double = 0
    @State private var sparkle2: Double = 0
    @State private var sparkle3: Double = 0
    @State private var phase = PhaseTracker()

    var body: some View {
        TimelineView(.animation) { timeline in
            let frame = phase.advance(
                to: timeline.date,
                state: state,
                level: Double(audioLevel)
            )

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
                .shadow(color: glowColor.opacity(0.4 + Double(audioLevel) * 0.3),
                        radius: 20 + CGFloat(audioLevel * 10))
                sparkles
            }
            .frame(width: haloSize, height: haloSize)
        }
        .onAppear { startSparkles() }
    }

    // ---- phase accumulator ----

    /// `@State` works for any class — SwiftUI just preserves the reference
    /// across renders. We don't need @Published since TimelineView already
    /// drives the redraw cadence.
    final class PhaseTracker {
        var phaseA: Double = 0
        var phaseB: Double = 2.1
        var pulsePhase: Double = 0
        var rotation: Double = 0
        private var lastDate: Date? = nil

        struct Frame {
            let pulse: CGFloat
            let haloOpacity: Double
            let driftA: Double
            let driftB: Double
            let driftAmplitude: Double
            let rotation: Double
        }

        func advance(to date: Date, state: OrbState, level: Double) -> Frame {
            // dt clamped to avoid huge jumps if the app was backgrounded.
            let dt: Double = {
                guard let last = lastDate else { return 0 }
                return min(0.1, date.timeIntervalSince(last))
            }()
            lastDate = date

            // State-tuned base parameters.
            let breath = breathingParams(for: state)
            let driftBase = blobBaseSpeed(for: state)
            let rotPeriod: Double = (state == .thinking) ? 4.5 : 22.0

            // Speed boosted by audio level (up to 2.5×).
            let driftSpeed = driftBase * (1.0 + level * 1.5)

            // INTEGRATE phase — when driftSpeed changes, only the next dt's
            // contribution changes; the past phase is preserved → no jumps.
            phaseA += dt * driftSpeed
            phaseB += dt * driftSpeed * 1.4
            // Pulse breathing also uses phase accumulator so rate changes don't jump.
            pulsePhase += dt * (.pi * 2 / breath.period)
            rotation += dt * (360.0 / rotPeriod)
            if rotation > 360 { rotation = rotation.truncatingRemainder(dividingBy: 360) }

            let breathPhase = (sin(pulsePhase) + 1) / 2     // 0..1
            let breathPulse = 1.0 + breathPhase * (breath.peak - 1.0)
            let pulse = breathPulse + level * 0.28

            let haloBase: Double = (state == .recording || state == .speaking) ? 0.58 : 0.45
            let haloOpacity = haloBase + level * 0.35

            // Blob radius: base + level boost.
            let amplitude = 22.0 + level * 16.0

            return Frame(
                pulse: CGFloat(pulse),
                haloOpacity: haloOpacity,
                driftA: phaseA,
                driftB: phaseB,
                driftAmplitude: amplitude,
                rotation: rotation
            )
        }

        private struct BreathParams { let period: Double; let peak: Double }

        private func breathingParams(for s: OrbState) -> BreathParams {
            switch s {
            case .idle:         return BreathParams(period: 3.2, peak: 1.05)
            case .thinking:     return BreathParams(period: 2.4, peak: 1.06)
            case .speaking:     return BreathParams(period: 1.3, peak: 1.16)
            case .recording:    return BreathParams(period: 1.6, peak: 1.04)
            case .transcribing: return BreathParams(period: 0.6, peak: 1.10)
            }
        }

        private func blobBaseSpeed(for s: OrbState) -> Double {
            // rad/sec at silence
            switch s {
            case .idle: return 0.8
            case .thinking: return 1.0
            case .speaking: return 1.6
            case .recording: return 1.4
            case .transcribing: return 2.4
            }
        }
    }

    // ---- layers ----

    private func outerAura(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(glowColor.opacity(opacity))
            .frame(width: haloSize, height: haloSize)
            .blur(radius: 55)
            .scaleEffect(scale)
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

    // ---- sparkles ----

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

    // ---- palette ----

    private var glowColor: Color {
        switch state {
        case .transcribing: return Color(red: 1.0, green: 0.72, blue: 0.18)
        default:            return Color(red: 0.20, green: 0.50, blue: 1.0)
        }
    }
    private var accentColor: Color {
        switch state {
        case .transcribing: return Color(red: 1.0, green: 0.92, blue: 0.55)
        default:            return Color(red: 0.45, green: 0.78, blue: 1.0)
        }
    }
}
