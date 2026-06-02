import SwiftUI

/// Liquid-glass orb. Uses iOS 26's native `.glassEffect(in:)` for the glass
/// material (real Metal pipeline — refraction, Fresnel edge, specular kiss,
/// press warp all included), with iridescent caustic blobs drifting BEHIND
/// the glass so there's actually something for the glass to refract. On a
/// pure black background a glass material renders as flat gray — the
/// colored backdrop is what makes it read as liquid.
///
/// Architecture (back to front):
///   1. Outer halo — large blurred radial gradient, sells "this thing glows"
///   2. Caustic backdrop — 3 colored discs drifting on slow lissajous orbits,
///      blended additively, blurred. This is what shows THROUGH the glass.
///   3. Glass orb — a clear circle with `.glassEffect(in: Circle())` overlaid
///      on top. iOS 26 SDK renders the actual liquid-glass material here.
///   4. Fallback for iOS 16-25: a hand-built ultraThinMaterial + Fresnel
///      rim stroke + specular highlight (close visual to v2 build 225).
///
/// Audio reactivity is exponentially smoothed (~167 ms time constant) so the
/// orb breathes/grows fluidly — never a discrete jump. Scale response is
/// modest (+30% at full voice) because most of the voice cue lives in the
/// caustic-blob orbit radius growth + halo brightening, not in the orb size.
struct VoiceOrbView: View {
    enum OrbState: Equatable {
        case idle, thinking, speaking, recording, transcribing
    }

    let state: OrbState
    var audioLevel: Float = 0    // 0..1, smoothed further inside PhaseTracker

    private let baseSize: CGFloat = 180
    /// Outer ZStack's reported layout size — kept moderate so the orb doesn't
    /// shove sibling views around. Halo layers RENDER larger than this via
    /// their own internal frames; SwiftUI .frame() doesn't clip, so the halo
    /// visually extends past this bound while the layout slot stays compact.
    private let haloMultiplier: CGFloat = 1.85
    /// The caustic backdrop extends BEYOND the glass circle so that as blobs
    /// drift, the refracted color inside the glass keeps changing — if the
    /// backdrop were the same size as the orb, the edges would always be the
    /// same color and the refraction would look dead.
    private let backdropMultiplier: CGFloat = 1.30

    @State private var phase = PhaseTracker()

    var body: some View {
        TimelineView(.animation) { timeline in
            let frame = phase.advance(
                to: timeline.date,
                state: state,
                rawLevel: Double(audioLevel)
            )

            ZStack {
                // Single soft halo (was two layers — outerHalo + ambientFalloff
                // — but their boundaries didn't coincide, creating a visible
                // darker ring at the discontinuity. One layer + many gradient
                // stops + heavy blur = no boundary).
                softHalo(scale: frame.pulse, opacity: frame.haloOpacity)

                // (2) caustic backdrop — clipped slightly larger than the
                // orb so the glass refracts a continuously-shifting color
                // pattern. The whole backdrop also rotates slowly (Frame
                // .backdropRotation) so the refracted light has a "lava
                // lamp slowly swirling" quality on top of the lissajous
                // drift of individual blobs. Rotation speed increases
                // gently with the smoothed audio level — louder voice =
                // slightly more swirl, but the curve is flat enough that
                // it never feels frenetic.
                causticBackdrop(frame: frame)
                    .frame(
                        width: baseSize * backdropMultiplier,
                        height: baseSize * backdropMultiplier
                    )
                    .rotationEffect(.degrees(frame.backdropRotation))
                    .clipShape(Circle())
                    .scaleEffect(frame.pulse)

                // (3) glass orb — the material itself.
                glassOrb
                    .scaleEffect(frame.pulse)
                    .shadow(
                        color: blueCaustic.opacity(0.35 + frame.smoothedLevel * 0.25),
                        radius: 18 + CGFloat(frame.smoothedLevel * 8)
                    )
            }
            .frame(width: baseSize * haloMultiplier, height: baseSize * haloMultiplier)
        }
    }

    // ---- The glass material (iOS 26 native; manual fallback below) ----

    @ViewBuilder
    private var glassOrb: some View {
        if #available(iOS 26.0, *) {
            // Native iOS 26 Liquid Glass. The Circle is clear — the material
            // does the entire job: refraction of the caustic backdrop, Fresnel
            // edge, specular, the lot. A tiny white tint nudges the overall
            // brightness up a notch without killing the transparency.
            Circle()
                .fill(Color.clear)
                .frame(width: baseSize, height: baseSize)
                .glassEffect(.regular.tint(.white.opacity(0.08)), in: Circle())
        } else {
            // iOS 16-25 fallback — hand-built to land close to the real
            // material visually. ultraThinMaterial does the frosted blur,
            // angular-gradient stroke fakes the Fresnel rim, a small radial
            // highlight fakes the specular kiss.
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.85)
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
                specularHighlight
            }
            .frame(width: baseSize, height: baseSize)
            .clipShape(Circle())
        }
    }

    // ---- Caustic backdrop (what the glass refracts) ----

    @ViewBuilder
    private func causticBackdrop(frame: PhaseTracker.Frame) -> some View {
        ZStack {
            causticBlob(color: blueCaustic, offset: frame.blobA, sizeScale: 1.10)
            causticBlob(color: pinkCaustic, offset: frame.blobB, sizeScale: 1.20)
            causticBlob(color: violetCaustic, offset: frame.blobC, sizeScale: 1.00)
        }
    }

    private func causticBlob(color: Color, offset: CGSize, sizeScale: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.95), color.opacity(0.45), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: baseSize * 0.48
                )
            )
            .frame(width: baseSize * sizeScale, height: baseSize * sizeScale)
            .offset(offset)
            .blur(radius: 22)
            .blendMode(.plusLighter)
    }

    // ---- Halo (back of stack) ----

    /// Single soft halo. Uses MANY gradient stops with monotonically-decreasing
    /// alpha so the curve is essentially smooth (no visible inflection where
    /// alpha drops). The frame is much larger than the gradient's endRadius
    /// (4.5× vs ~2.0×) so the heavy blur has room to work past the gradient
    /// boundary without hitting a frame edge. Result: light dissolves into
    /// black with no perceptible ring. Does NOT scale with breath — keeping
    /// the halo stable while the orb pulses prevents an animated boundary
    /// from drawing the eye to its position.
    private func softHalo(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: blueCaustic.opacity(opacity * 1.00), location: 0.00),
                        .init(color: blueCaustic.opacity(opacity * 0.75), location: 0.18),
                        .init(color: violetCaustic.opacity(opacity * 0.50), location: 0.32),
                        .init(color: violetCaustic.opacity(opacity * 0.30), location: 0.46),
                        .init(color: pinkCaustic.opacity(opacity * 0.16), location: 0.60),
                        .init(color: pinkCaustic.opacity(opacity * 0.07), location: 0.74),
                        .init(color: pinkCaustic.opacity(opacity * 0.02), location: 0.88),
                        .init(color: .clear, location: 1.00),
                    ]),
                    center: .center,
                    startRadius: 3,
                    endRadius: baseSize * 2.0
                )
            )
            .frame(width: baseSize * 4.5, height: baseSize * 4.5)
            .blur(radius: 60)
    }

    /// Fallback-only specular kiss for iOS 16-25.
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
        var backdropRotation: Double = 0   // accumulated degrees, mod 360 on the way out
        private var lastDate: Date? = nil

        struct Frame {
            let pulse: CGFloat
            let haloOpacity: Double
            let smoothedLevel: Double
            let blobA: CGSize
            let blobB: CGSize
            let blobC: CGSize
            /// Degrees applied to the caustic backdrop's parent transform.
            /// Slowly accumulates so the swirl doesn't appear to snap.
            let backdropRotation: Double
        }

        func advance(to date: Date, state: OrbState, rawLevel: Double) -> Frame {
            let dt: Double = {
                guard let last = lastDate else { return 0 }
                return min(0.1, date.timeIntervalSince(last))
            }()
            lastDate = date
            t += dt

            // Exponential smoothing — ~167 ms time constant. Slow enough
            // that loud-then-quiet bursts blend, fast enough that the orb
            // still feels responsive.
            let rate = 6.0
            let factor = min(1.0, dt * rate)
            smoothedLevel += (rawLevel - smoothedLevel) * factor
            smoothedLevel = max(0, min(1, smoothedLevel))

            let breath = breathingParams(for: state)
            pulsePhase += dt * (.pi * 2 / breath.period)
            let breathFrac = (sin(pulsePhase) + 1) / 2
            let breathPulse = 1.0 + breathFrac * (breath.peak - 1.0)

            // Modest audio-reactive scale (+30% at full voice).
            let levelGrowth = smoothedLevel * 0.30
            let pulse = breathPulse + levelGrowth

            let haloBase: Double = (state == .recording || state == .speaking) ? 0.55 : 0.40
            let haloOpacity = haloBase + smoothedLevel * 0.25

            // Lissajous orbits with incommensurate frequencies (no visible
            // loop point). Orbit radius grows slightly with smoothedLevel
            // so blobs sweep wider on louder voice.
            let r = 22.0 + smoothedLevel * 14.0
            let aX = cos(t * 0.18) * r
            let aY = sin(t * 0.22 + 1.0) * r
            let bX = cos(t * 0.16 + 2.0) * r * 1.10
            let bY = sin(t * 0.20 + 3.0) * r * 0.90
            let cX = cos(t * 0.14 + 4.0) * r * 0.95
            let cY = sin(t * 0.18 + 5.0) * r * 1.10

            // Backdrop rotation: base 4°/s + up to +6°/s on loud voice =
            // ~one full revolution every 90 s at rest, ~36 s at full voice.
            // Always positive (CCW) so the direction doesn't flip when
            // smoothedLevel oscillates.
            let degPerSec = 4.0 + smoothedLevel * 6.0
            backdropRotation += dt * degPerSec
            // Keep the value bounded so it doesn't drift toward floating-
            // point precision loss over a long session.
            if backdropRotation > 360 { backdropRotation -= 360 }

            return Frame(
                pulse: CGFloat(pulse),
                haloOpacity: haloOpacity,
                smoothedLevel: smoothedLevel,
                blobA: CGSize(width: aX, height: aY),
                blobB: CGSize(width: bX, height: bY),
                blobC: CGSize(width: cX, height: cY),
                backdropRotation: backdropRotation
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
