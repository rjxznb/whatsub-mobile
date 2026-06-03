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
    /// True while the user is holding the orb (push-to-talk gesture).
    /// When true: (a) "push me" label hides; (b) halo rotation speeds up
    /// to give immediate visual confirmation that the press registered.
    var isPressed: Bool = false

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
                rawLevel: Double(audioLevel),
                isPressed: isPressed
            )
            // Continuous time for the Metal shader. We modulo to [0, 1000) s
            // before converting to Float — `timeIntervalSinceReferenceDate`
            // is ~7e8 s today, and Float32 has only ~7 sig figs so the
            // shader's `time * 2.0` term would lose sub-second resolution.
            // 1000 s of headroom keeps the rotating-hotspot animation smooth
            // and the period-mismatch at the wrap is invisible (modulo 1000
            // doesn't align with any of the shader's frequencies).
            let t = Float(timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1000))

            ZStack {
                // The Metal shader IS the orb. Builds 235-240 stacked a
                // Liquid Glass body + caustic backdrop + under-light on top
                // of the shader — user feedback (2026-06-03, screenshot
                // arrow pointing at the inner dark sphere) made it clear
                // that the extra layers were just clutter on top of an
                // already-complete React-Bits visual. Stripped to the
                // shader + the press-me label.
                if #available(iOS 17.0, *) {
                    shaderGlow(time: t, level: frame.smoothedLevel, pressed: isPressed)
                        .scaleEffect(frame.pulse)
                } else {
                    // iOS 16 path — no Metal stitchables on this version.
                    // Fall back to the previous multi-stop soft halo so
                    // there's still SOMETHING to look at + the press gesture
                    // still has a tap target.
                    softHalo(scale: frame.pulse, opacity: frame.haloOpacity)
                }

                // "press me" prompt — hides during press so the orb visual
                // is uncluttered while talking. Sits in the shader's dark
                // central region.
                if !isPressed {
                    pushMeLabel(time: timeline.date)
                        .frame(width: baseSize, height: baseSize)
                        .scaleEffect(frame.pulse)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.18), value: isPressed)
                }
            }
            .frame(width: baseSize * haloMultiplier, height: baseSize * haloMultiplier)
            // (A) Press-pop. Spring scale on top of the breath/voice pulse.
            // User feedback 2026-06-03: previous values (1.12 scale, 250ms
            // response, dampingFraction 0.6) felt too "shu-li" (over-windup)
            // — too big, too long, too bouncy. Toned to a snappier 1.06 /
            // 150ms / 0.85 damping: subtle confirm-only nudge, no theatrics.
            .scaleEffect(isPressed ? 1.06 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.85), value: isPressed)
        }
    }

    // ---- The glass material (iOS 26 native; manual fallback below) ----

    @ViewBuilder
    private var glassOrb: some View {
        if #available(iOS 26.0, *) {
            // Native iOS 26 Liquid Glass. The Circle is clear — the material
            // does the entire job: refraction of the caustic backdrop, Fresnel
            // edge, specular, the lot. Tint .04 (was .08 in build 233) so the
            // caustic shows through more vividly — the React-Bits GlassSurface
            // reference (2026-06-03) is high transparency + strong refraction.
            // .interactive() adds press-warp + slight motion response.
            Circle()
                .fill(Color.clear)
                .frame(width: baseSize, height: baseSize)
                .glassEffect(.regular.tint(.white.opacity(0.04)).interactive(),
                             in: Circle())
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

    // ---- Halo: Metal shader (iOS 17+) ----

    /// Bright sized so the shader's bright ring (at uv ≈ 0.6) sits just
    /// outside the Liquid Glass orb's circumference. Math:
    ///   uv = (px - center) / minDim * 2
    ///   bright ring at uv 0.6 ⇒ position 0.3 * minDim from center
    ///   want that at (baseSize/2) * 1.10 ⇒ minDim ≈ baseSize * 1.83
    /// We use 2.0 to give the outer fade some breathing room past the
    /// halo-multiplier frame.
    private var shaderSize: CGFloat { baseSize * 2.0 }

    /// Render the OrbGlow shader. The Rectangle is given a non-transparent
    /// fill so .colorEffect has pixels to operate on; the shader overwrites
    /// the color with its own pre-multiplied output.
    @available(iOS 17.0, *)
    @ViewBuilder
    private func shaderGlow(time: Float, level: Double, pressed: Bool) -> some View {
        Rectangle()
            .fill(Color.white)
            .colorEffect(
                ShaderLibrary.orbGlow(
                    .float2(CGSize(width: shaderSize, height: shaderSize)),
                    .float(time),
                    .float(Float(level)),
                    .float(pressed ? 1.0 : 0.0)
                )
            )
            .frame(width: shaderSize, height: shaderSize)
    }

    /// "press me" prompt — glass-style text + animated left→right highlight
    /// sweep. The sweep is implemented as a 3-stop LinearGradient mask
    /// overlay on top of a base muted version of the text; offset of the
    /// mask is driven by `time` so the bright band travels horizontally
    /// across the text every 2.4 s. Material foreground style gives the
    /// text itself a frosted-glass appearance to match the orb body.
    @ViewBuilder
    private func pushMeLabel(time: Date) -> some View {
        let text = "press me"
        // 0..1 sweep phase, loop every 2.4 s.
        let phase = time.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 2.4) / 2.4
        // Map phase to a horizontal offset that takes the bright band from
        // off-left (-baseSize) to off-right (+baseSize) over one loop.
        let offsetX = CGFloat(phase - 0.5) * baseSize * 1.6

        // Base text: dim frosted-glass material. The brighter sweep then
        // briefly lifts each character as it passes through.
        ZStack {
            Text(text)
                .font(.custom("Caveat-Bold", size: 44))
                .foregroundStyle(.regularMaterial.opacity(0.65))

            // Highlight pass — same text, full-white, masked by a moving
            // gradient band so only the slice currently under the band lights up.
            Text(text)
                .font(.custom("Caveat-Bold", size: 44))
                .foregroundStyle(.white)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear,             location: 0.20),
                            .init(color: .white.opacity(0.95), location: 0.50),
                            .init(color: .clear,             location: 0.80),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: baseSize * 0.85)
                    .offset(x: offsetX)
                )
        }
    }

    /// Soft bright pool just below the orb. Centered ~0.4 baseSize below
    /// the orb center so its top edge overlaps with the orb's lower
    /// hemisphere — the Liquid Glass layer above then refracts the
    /// overlapping portion, making the light visibly "diffuse through" the
    /// orb. Brightness lifts gently with smoothed audio level.
    private func underLight(level: Double) -> some View {
        let intensity = 0.55 + level * 0.35
        return Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.45, green: 0.65, blue: 1.00).opacity(intensity),
                        Color(red: 0.55, green: 0.40, blue: 0.95).opacity(intensity * 0.55),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 4,
                    endRadius: baseSize * 0.55
                )
            )
            .frame(width: baseSize * 1.10, height: baseSize * 0.75)
            .offset(y: baseSize * 0.40)
            .blur(radius: 26)
            .blendMode(.plusLighter)
    }

    // ---- Halo: legacy gradient fallback (iOS 16) ----

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

        func advance(to date: Date, state: OrbState, rawLevel: Double, isPressed: Bool = false) -> Frame {
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
            // Press multiplier toned 4× → 2× to match the rest of the
            // press-reaction de-escalation (user feedback 2026-06-03).
            var degPerSec = 4.0 + smoothedLevel * 6.0
            if isPressed { degPerSec *= 2.0 }
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
