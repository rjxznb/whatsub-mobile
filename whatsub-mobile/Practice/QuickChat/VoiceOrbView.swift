import SwiftUI

/// Siri-style iridescent glow orb. Bright emissive body with cyan/pink/white
/// gradients and a slowly rotating white "swoosh" wisp inside. Audio-reactive:
/// the whole orb scales up dramatically with mic level (the size IS the
/// listening signal — no color flip).
///
/// Layers, back to front:
/// 1. Soft outer glow — cyan halo, blurred, scales with size + pulse
/// 2. Pink/lavender tint wisp — slow rotating elongated ellipse, very blurred,
///    gives the orb its iridescent secondary hue at the edges
/// 3. Cyan/white body — radial gradient from near-white center → bright cyan
///    → soft cyan edge. This is the visible "orb"
/// 4. White swoosh wisp — slowly rotating bright white ellipse (the Siri
///    signature brushstroke); clipped to the orb circle, heavily blurred
/// 5. Top highlight — small bright spot upper-right for the glass sheen
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle, thinking, speaking, recording, transcribing
    }

    let state: OrbState
    var audioLevel: Float = 0    // 0..1, smoothed in VADCoordinator

    /// Resting orb diameter. Grows up to (baseSize × ~1.85) on loud voice.
    private let baseSize: CGFloat = 180
    private let haloMultiplier: CGFloat = 1.8
    private let scaleBoost: Double = 0.85       // up to +85% at full voice

    @State private var phase = PhaseTracker()

    var body: some View {
        TimelineView(.animation) { timeline in
            let frame = phase.advance(
                to: timeline.date,
                state: state,
                level: Double(audioLevel)
            )

            ZStack {
                outerGlow(scale: frame.pulse, opacity: frame.haloOpacity)
                ZStack {
                    pinkWisp(rotation: frame.wispRotationA)
                    orbBody
                    whiteSwoosh(rotation: frame.wispRotationB)
                    topHighlight
                }
                .frame(width: baseSize, height: baseSize)
                .clipShape(Circle())
                .scaleEffect(frame.pulse)
                .shadow(color: cyanGlow.opacity(0.5 + Double(audioLevel) * 0.3),
                        radius: 18 + CGFloat(audioLevel * 12))
            }
            .frame(width: baseSize * haloMultiplier, height: baseSize * haloMultiplier)
        }
    }

    // ---- Layers ----

    private func outerGlow(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [cyanGlow.opacity(opacity), pinkGlow.opacity(opacity * 0.5), .clear],
                    center: .center,
                    startRadius: 5,
                    endRadius: baseSize * 0.9
                )
            )
            .frame(width: baseSize * haloMultiplier, height: baseSize * haloMultiplier)
            .blur(radius: 30)
            .scaleEffect(scale)
    }

    private func pinkWisp(rotation: Double) -> some View {
        // Elongated pink-lavender shape; less blur (20→14) so the iridescent
        // tint is clearly readable as a hue gradient sweeping across the orb.
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [pinkGlow.opacity(0.0), pinkGlow.opacity(0.95), pinkGlow.opacity(0.0)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: baseSize * 1.18, height: baseSize * 0.55)
            .rotationEffect(.degrees(rotation))
            .blur(radius: 14)
    }

    /// The bright emissive core. White-cyan center fading to soft cyan edge.
    private var orbBody: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.96, green: 0.99, blue: 1.0),                  // near white center
                        Color(red: 0.55, green: 0.85, blue: 1.0),                  // bright sky cyan
                        Color(red: 0.30, green: 0.65, blue: 0.95).opacity(0.85)    // softer cyan edge
                    ],
                    center: UnitPoint(x: 0.45, y: 0.40),
                    startRadius: 0,
                    endRadius: baseSize * 0.55
                )
            )
            .frame(width: baseSize, height: baseSize)
    }

    private func whiteSwoosh(rotation: Double) -> some View {
        // Bright white brushstroke flowing through the orb. Less blur than v1
        // (14 → 8) so the stroke is clearly visible as a moving shape, not just
        // a diffuse glow. Slightly elongated so it looks like a curved sweep.
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.0), .white.opacity(1.0), .white.opacity(0.0)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: baseSize * 1.1, height: baseSize * 0.42)
            .rotationEffect(.degrees(rotation))
            .blur(radius: 8)
            .blendMode(.plusLighter)
    }

    private var topHighlight: some View {
        // Small concentrated bright spot upper-right (like Siri's gloss).
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.75), .white.opacity(0.15), .clear],
                    center: UnitPoint(x: 0.32, y: 0.27),
                    startRadius: 1,
                    endRadius: baseSize * 0.35
                )
            )
            .frame(width: baseSize, height: baseSize)
            .blendMode(.plusLighter)
    }

    // ---- palette ----

    private var cyanGlow: Color {
        switch state {
        case .transcribing: return Color(red: 1.0, green: 0.85, blue: 0.45)   // warm shift only here
        default:            return Color(red: 0.40, green: 0.75, blue: 1.0)   // sky cyan
        }
    }

    private var pinkGlow: Color {
        switch state {
        case .transcribing: return Color(red: 1.0, green: 0.65, blue: 0.25)
        default:            return Color(red: 0.98, green: 0.62, blue: 0.85)  // soft pink-lavender
        }
    }

    // ---- phase accumulator (preserves smoothness when speed changes) ----

    final class PhaseTracker {
        var pulsePhase: Double = 0
        var wispA: Double = 0
        var wispB: Double = .pi / 2     // start 90° apart
        private var lastDate: Date? = nil

        struct Frame {
            let pulse: CGFloat
            let haloOpacity: Double
            let wispRotationA: Double
            let wispRotationB: Double
        }

        func advance(to date: Date, state: OrbState, level: Double) -> Frame {
            let dt: Double = {
                guard let last = lastDate else { return 0 }
                return min(0.1, date.timeIntervalSince(last))
            }()
            lastDate = date

            let breath = breathingParams(for: state)
            let wispBase = wispBaseSpeed(for: state)
            // Audio level accelerates wisps strongly (up to ~3.5× faster on loud voice)
            // so the white swoosh visibly streaks across the orb when user speaks.
            let wispSpeed = wispBase * (1.0 + level * 2.5)

            pulsePhase += dt * (.pi * 2 / breath.period)
            wispA += dt * wispSpeed * 60         // 60 = scale to deg/sec
            wispB += dt * wispSpeed * 60 * 1.4   // counter-rotating-ish (different rate)

            let breathFrac = (sin(pulsePhase) + 1) / 2      // 0..1
            let breathPulse = 1.0 + breathFrac * (breath.peak - 1.0)
            // Audio level adds dramatic growth: up to +85% scale on loud voice.
            // Combined with breathing's ~+10% peak, max effective scale ≈ 1.85-2.0×.
            let levelGrowth = level * 0.85
            let pulse = breathPulse + levelGrowth

            let haloBase: Double = (state == .recording || state == .speaking) ? 0.55 : 0.40
            let haloOpacity = haloBase + level * 0.30

            return Frame(
                pulse: CGFloat(pulse),
                haloOpacity: haloOpacity,
                wispRotationA: wispA.truncatingRemainder(dividingBy: 360),
                wispRotationB: wispB.truncatingRemainder(dividingBy: 360)
            )
        }

        private struct BreathParams { let period: Double; let peak: Double }

        private func breathingParams(for s: OrbState) -> BreathParams {
            switch s {
            case .idle:         return BreathParams(period: 4.0, peak: 1.04)
            case .thinking:     return BreathParams(period: 2.6, peak: 1.05)
            case .speaking:     return BreathParams(period: 1.4, peak: 1.10)
            case .recording:    return BreathParams(period: 2.0, peak: 1.03)   // breath subtle; level boosts the rest
            case .transcribing: return BreathParams(period: 0.7, peak: 1.08)
            }
        }

        private func wispBaseSpeed(for s: OrbState) -> Double {
            // rotation rate (1.0 = baseline)
            switch s {
            case .idle: return 0.3
            case .thinking: return 0.45
            case .speaking: return 0.6
            case .recording: return 0.5
            case .transcribing: return 0.85
            }
        }
    }
}
