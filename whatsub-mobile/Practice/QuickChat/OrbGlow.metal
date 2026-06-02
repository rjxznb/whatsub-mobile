// OrbGlow.metal
//
// Port of the React-Bits Orb fragment shader (https://reactbits.dev/orb)
// to a SwiftUI `.colorEffect` stitchable function. Used by VoiceOrbView to
// paint an animated glow/halo around the Liquid Glass orb.
//
// Differences from the React-Bits source (deliberate):
//   • No hover-distortion path (`uv.x += hover * hoverIntensity ...`) — the
//     user explicitly asked for "周围发光动画 but no hover deformation"
//     (2026-06-03). `hover` was effectively a touch-tracking uniform that
//     we have no equivalent input for in a stitchable shader anyway.
//   • No `rotateOnHover` accumulator — the orbiting hotspot uses `time`
//     directly so the rotation is continuous (slow, ambient).
//   • Background luminance is hard-coded to 0 (the QuickChat bg is pure
//     black). Simplifies the dark/light branch in `draw()` to just the
//     dark variant.
//   • Pre-multiplied alpha output matches what SwiftUI's compositor
//     expects from .colorEffect.
//
// Coordinate convention:
//   `position` is in the view's POINT space (SwiftUI passes points, not
//   pixels). We pass the view's bounds size as the `size` argument so we
//   can compute the centered UV without depending on pixel scale.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ---- noise helpers (ported 1:1 from the GLSL) ----

static inline float3 hash33(float3 p3) {
    p3 = fract(p3 * float3(0.1031, 0.11369, 0.13787));
    p3 += dot(p3, p3.yxz + 19.19);
    return -1.0 + 2.0 * fract(float3(p3.x + p3.y,
                                     p3.x + p3.z,
                                     p3.y + p3.z) * p3.zyx);
}

static inline float snoise3(float3 p) {
    const float K1 = 0.333333333;
    const float K2 = 0.166666667;
    float3 i  = floor(p + (p.x + p.y + p.z) * K1);
    float3 d0 = p - (i - (i.x + i.y + i.z) * K2);
    float3 e  = step(float3(0.0), d0 - d0.yzx);
    float3 i1 = e * (1.0 - e.zxy);
    float3 i2 = 1.0 - e.zxy * (1.0 - e);
    float3 d1 = d0 - (i1 - K2);
    float3 d2 = d0 - (i2 - K1);
    float3 d3 = d0 - 0.5;
    float4 h  = max(0.6 - float4(dot(d0, d0),
                                 dot(d1, d1),
                                 dot(d2, d2),
                                 dot(d3, d3)),
                    0.0);
    float4 n  = h * h * h * h * float4(dot(d0, hash33(i)),
                                       dot(d1, hash33(i + i1)),
                                       dot(d2, hash33(i + i2)),
                                       dot(d3, hash33(i + 1.0)));
    return dot(float4(31.316), n);
}

// ---- lighting helpers ----

static inline float light1(float intensity, float attenuation, float dist) {
    return intensity / (1.0 + dist * attenuation);
}
static inline float light2(float intensity, float attenuation, float dist) {
    return intensity / (1.0 + dist * dist * attenuation);
}

// ---- palette (matches whatSub brand: blue + violet + deep navy) ----

constant float3 baseColor1 = float3(0.611765, 0.262745, 0.996078);  // violet
constant float3 baseColor2 = float3(0.298039, 0.760784, 0.913725);  // cyan-blue
constant float3 baseColor3 = float3(0.062745, 0.078431, 0.600000);  // deep navy
constant float  innerRadius = 0.6;
constant float  noiseScale  = 0.65;

[[stitchable]] half4 orbGlow(float2 position,
                             half4   /*existingColor*/,
                             float2  size,
                             float   time,
                             float   boost)
{
    float2 center = size * 0.5;
    float  minDim = min(size.x, size.y);
    float2 uv     = (position - center) / minDim * 2.0;
    float  len    = length(uv);

    // ---- Hard mask 1: inside the glass orb (uv 0..~0.52) → fully transparent.
    //
    // The Liquid Glass orb sits at uv 0.5 (its outer edge). Anything we
    // draw inside that radius would (a) be refracted by the glass into a
    // muddy double-image and (b) leak our halo color into the orb body,
    // killing the clean glass + caustic interior the user just asked for.
    // Output zero alpha here. The glass-orb layer + the caustic backdrop
    // both handle pixels inside this radius.
    if (len < 0.52) return half4(0.0h);

    // ---- Hard mask 2: far outside (uv > 1.05) → transparent.
    if (len > 1.05) return half4(0.0h);

    // ---- Soft donut envelope ----
    //
    // Build a smooth ring of intensity ONLY in the band 0.52..1.0, peaking
    // around 0.75. No bright concentric ring + no orbiting hotspot (per
    // the user's "只保留外面的那个环" feedback — those were the visible
    // "inner ring" we just removed). Just a soft fade with a noisy outer
    // edge so it doesn't look perfectly geometric.
    float n0 = snoise3(float3(uv * noiseScale, time * 0.4)) * 0.5 + 0.5;
    float innerEdge = smoothstep(0.52, 0.65, len);            // rises just outside the glass orb
    float outerEdge = 1.0 - smoothstep(0.85 + n0 * 0.10, 1.05, len);  // noisy outer fade
    float donut     = innerEdge * outerEdge;

    // ---- Angular color cycle (slow) ----
    //
    // Drift between violet and cyan-blue around the ring, completing one
    // full angular cycle ~every 12 s. Slow enough to feel like ambient
    // shimmer rather than a strobe.
    float ang = atan2(uv.y, uv.x);
    float cl  = cos(ang + time * 0.5) * 0.5 + 0.5;
    float3 colBase = mix(baseColor1, baseColor2, cl);

    // ---- Vertical asymmetry: "light from below disperses through" ----
    //
    // SwiftUI's position coord system has y growing DOWN, so uv.y > 0 is
    // the lower half. We make the lower half brighter so the orb reads as
    // sitting on a soft pool of light that radiates UP through it. The
    // factor goes 0.55 (top) → 1.00 (bottom).
    float verticalLift = mix(0.55, 1.00, clamp(uv.y * 0.5 + 0.5, 0.0, 1.0));
    float intensity    = donut * verticalLift;

    // `boost` (0..1, smoothed audio level) lifts overall brightness when
    // someone is talking. Conservative ×0.6 so loud voice doesn't blow
    // the halo out.
    float gain = 1.0 + boost * 0.6;
    float3 outColor = colBase * intensity * gain;
    outColor = clamp(outColor, 0.0, 1.0);

    // Pre-multiplied alpha output (matches SwiftUI compositor expectations).
    float aOut = max(max(outColor.r, outColor.g), outColor.b);
    return half4(half3(outColor), half(aOut));
}
