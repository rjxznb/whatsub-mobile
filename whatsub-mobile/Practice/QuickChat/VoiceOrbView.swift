import SwiftUI

/// Liquid-glass orb. Replaces the v1 Siri emissive orb with a translucent
/// glass body that has slow-drifting caustic color blobs inside, a bright
/// Fresnel-style rim, and a small specular highlight up top.
///
/// Audio reactivity is exponentially smoothed (~150 ms time constant) so the
/// orb breathes/grows fluidly with voice — never a discrete jump. Scale
/// response is also less aggressive than v1 (was +85% on full voice, now ~+30%)
/// because the visual cue here is the caustic motion + rim brighten, not
/// dramatic size pumping.
///
/// Layers, back to front:
/// 1. Soft outer halo — large blurred radial glow that grows with smoothed
///    level. Tinted cyan/pink.
/// 2. Caustic backdrop — three blurred colored discs (blue/pink/violet) drifting
///    inside slow lissajous orbits, blended additively for the iridescent
///    "liquid swirl" look. This is what shows THROUGH the glass.
/// 3. Glass tint — thin white fog so the caustic doesn't read as raw color.
/// 4. Inner rim shadow — soft dark vignette near the inside edge giving the
///    "thick glass shell" depth cue.
/// 5. Rim highlight — angular gradient stroke around the edge, bright at the
///    upper-left, dim at the lower-right (light source convention).
/// 6. Specular highlight — small bright spot upper-left for the gloss kiss.
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle, thinking, speaking, recording, transcribing
    }

    let state: OrbState
    var audioLevel: Float = 0    // 0..1, smoothed further inside PhaseTracker

    private let baseSize: CGFloat = 180
    private let haloMultiplier: CGFloat = 1.85

    @State private var phase = PhaseTracker()

    var body: some View {
        TimelineView(.animation) { timeline in
            let frame = phase.advance(
                to: timeline.date,
                state: state,
                rawLevel: Double(audioLevel)
            )

            ZStack {
                outerHalo(scale: frame.pulse, opacity: frame.haloOpacity)

                ZStack {
                    // (2) caustic backdrop
                    causticBlob(color: blueCaustic, offset: frame.blobA, scale: 1.10)
                    causticBlob(color: pinkCaustic, offset: frame.blobB, scale: 1.20)
                    causticBlob(color: violetCaustic, offset: frame.blobC, scale: 1.00)

                    // (3) glass tint — slight white wash so the caustic reads
                    // as "fluid behind glass", not as raw color.
                    Circle().fill(.white.opacity(0.06))

                    // (4) inner rim shadow (thick-glass depth cue)
                    Circle()
                        .strokeBorder(
                            RadialGradient(
                                colors: [.clear, .black.opacity(0.0), .black.opacity(0.25)],
                                center: .center,
                                startRadius: baseSize * 0.30,
                                endRadius: baseSize * 0.50
                            ),
                            lineWidth: 18
                        )
                        .blur(radius: 6)

                    // (5) rim highlight (Fresnel-style)
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    .white.opacity(0.95),
                                    .white.opacity(0.10),
                                    .white.opacity(0.35),
                                    .white.opacity(0.05),
                                    .white.opacity(0.95),
                                ],
                                center: .center,
                                angle: .degrees(-45)
                            ),
                            lineWidth: 2.0
                        )
                        .blur(radius: 0.6)

                    // (6) specular highlight upper-left
                    specularHighlight
                }
                .frame(width: baseSize, height: baseSize)
                .clipShape(Circle())
                .scaleEffect(frame.pulse)
                // Soft cyan ambient shadow underneath, brightens with voice.
                .shadow(
                    color: blueCaustic.opacity(0.35 + frame.smoothedLevel * 0.25),
                    radius: 18 + CGFloat(frame.smoothedLevel * 8)
                )
            }
            .frame(width: baseSize * haloMultiplier, height: baseSize * haloMultiplier)
        }
    }

    // ---- Layers ----

    private func outerHalo(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [blueCaustic.opacity(opacity), pinkCaustic.opacity(opacity * 0.4), .clear],
                    center: .center,
                    startRadius: 5,
                    endRadius: baseSize * 0.9
                )
            )
            .frame(width: baseSize * haloMultiplier, height: baseSize * haloMultiplier)
            .blur(radius: 30)
            .scaleEffect(scale)
    }

    /// One drifting caustic disc — radial gradient with heavy blur.
    private func causticBlob(color: Color, offset: CGSize, scale: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.95), color.opacity(0.45), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: baseSize * 0.48
                )
            )
            .frame(width: baseSize * scale, height: baseSize * scale)
            .offset(offset)
            .blur(radius: 20)
            .blendMode(.plusLighter)
    }

    private var specularHighlight: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.80), .white.opacity(0.10), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: baseSize * 0.18
                )
            )
            .frame(width: baseSize * 0.45, height: baseSize * 0.30)
            .rotationEffect(.degrees(-35))
            .offset(x: -baseSize * 0.18, y: -baseSize * 0.20)
            .blur(radius: 4)
            .blendMode(.plusLighter)
    }

    // ---- palette ----
    // Saturated jewel tones — caustic blobs are blended additively so the
    // visible result is softer pastel where they overlap.

    private var blueCaustic: Color {
        switch state {
        case .transcribing: return Color(red: 1.00, green: 0.85, blue: 0.45)
        default:            return Color(red: 0.30, green: 0.65, blue: 1.00)
        }
    }
    private var pinkCaustic: Color {
        switch state {
        case .transcribing: return Color(red: 1.00, green: 0.55, blue: 0.20)
        default:            return Color(red: 0.95, green: 0.45, blue: 0.85)
        }
    }
    private var violetCaustic: Color {
        switch state {
        case .transcribing: return Color(red: 0.95, green: 0.65, blue: 0.30)
        default:            return Color(red: 0.55, green: 0.40, blue: 0.95)
        }
    }

    // ---- phase tracker (level smoothing + lissajous drift) ----

    final class PhaseTracker {
        var pulsePhase: Double = 0
        var smoothedLevel: Double = 0
        var t: Double = 0
        private var lastDate: Date? = nil

        struct Frame {
            let pulse: CGFloat
            let haloOpacity: Double
            let smoothedLevel: Double
            let blobA: CGSize
            let blobB: CGSize
            let blobC: CGSize
        }

        func advance(to date: Date, state: OrbState, rawLevel: Double) -> Frame {
            let dt: Double = {
                guard let last = lastDate else { return 0 }
                return min(0.1, date.timeIntervalSince(last))
            }()
            lastDate = date
            t += dt

            // Exponential smoothing of the level. `rate` of 6 ≈ 167 ms time
            // constant — slow enough that loud-then-quiet bursts blend, fast
            // enough that the orb still feels responsive. Critically, we
            // smooth EVERY frame (not just on big jumps) so there's never a
            // discrete pop — the user's #1 complaint about the v1 orb.
            let rate = 6.0
            let factor = min(1.0, dt * rate)
            smoothedLevel += (rawLevel - smoothedLevel) * factor
            smoothedLevel = max(0, min(1, smoothedLevel))

            // Breathing — slow ambient sin for "alive" feel.
            let breath = breathingParams(for: state)
            pulsePhase += dt * (.pi * 2 / breath.period)
            let breathFrac = (sin(pulsePhase) + 1) / 2
            let breathPulse = 1.0 + breathFrac * (breath.peak - 1.0)

            // Audio-reactive scale: gentler than v1 (was +85% peak; now +30%).
            // Most of the voice cue is delivered by caustic-blob drift +
            // halo brightening, not dramatic size pumping.
            let levelGrowth = smoothedLevel * 0.30
            let pulse = breathPulse + levelGrowth

            let haloBase: Double = (state == .recording || state == .speaking) ? 0.55 : 0.40
            let haloOpacity = haloBase + smoothedLevel * 0.25

            // Blob drift — slow lissajous orbits at different rates + phases.
            // The frequencies are deliberately incommensurate so the pattern
            // never visually repeats (no perceived loop). Radius grows
            // slightly with smoothedLevel so blobs sweep wider on louder
            // voice — adds energy without snap.
            let r = 20.0 + smoothedLevel * 12.0
            let aX = cos(t * 0.18) * r
            let aY = sin(t * 0.22 + 1.0) * r
            let bX = cos(t * 0.16 + 2.0) * r * 1.10
            let bY = sin(t * 0.20 + 3.0) * r * 0.90
            let cX = cos(t * 0.14 + 4.0) * r * 0.95
            let cY = sin(t * 0.18 + 5.0) * r * 1.10

            return Frame(
                pulse: CGFloat(pulse),
                haloOpacity: haloOpacity,
                smoothedLevel: smoothedLevel,
                blobA: CGSize(width: aX, height: aY),
                blobB: CGSize(width: bX, height: bY),
                blobC: CGSize(width: cX, height: cY)
            )
        }

        private struct BreathParams { let period: Double; let peak: Double }

        private func breathingParams(for s: OrbState) -> BreathParams {
            switch s {
            case .idle:         return BreathParams(period: 4.0, peak: 1.04)
            case .thinking:     return BreathParams(period: 2.6, peak: 1.05)
            case .speaking:     return BreathParams(period: 1.4, peak: 1.08)
            case .recording:    return BreathParams(period: 2.4, peak: 1.03)
            case .transcribing: return BreathParams(period: 0.7, peak: 1.07)
            }
        }
    }
}
