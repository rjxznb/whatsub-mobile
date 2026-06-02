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

    // Outside the visible footprint we want pure transparent — short-circuit
    // so the shader doesn't waste cycles + so the soft fade never goes
    // negative which could darken neighboring pixels via premultiply.
    float len = length(uv);
    if (len > 1.10) return half4(0.0h);

    float ang    = atan2(uv.y, uv.x);
    float invLen = len > 0.0 ? 1.0 / len : 0.0;

    // Noisy edge — animated radial perturbation.
    float n0 = snoise3(float3(uv * noiseScale, time * 0.5)) * 0.5 + 0.5;
    float r0 = mix(mix(innerRadius, 1.0, 0.4),
                   mix(innerRadius, 1.0, 0.6),
                   n0);
    float d0 = distance(uv, (r0 * invLen) * uv);
    float v0 = light1(1.0, 10.0, d0);
    v0 *= smoothstep(r0 * 1.05, r0, len);

    float innerFade = smoothstep(r0 * 0.8, r0 * 0.95, len);
    v0 *= innerFade;   // bgLuminance branch collapsed to 0

    // Color cycle around the ring.
    float cl = cos(ang + time * 2.0) * 0.5 + 0.5;

    // Orbiting bright hotspot — rotates CCW at ~one revolution per 2π s
    // (≈ 6.3 s). This is the "rotating glow" the user asked for.
    float  a   = time * -1.0;
    float2 pos = float2(cos(a), sin(a)) * r0;
    float  d   = distance(uv, pos);
    float  v1  = light2(1.5, 5.0, d);
    v1 *= light1(1.0, 50.0, d0);

    float v2 = smoothstep(1.0, mix(innerRadius, 1.0, n0 * 0.5), len);
    float v3 = smoothstep(innerRadius, mix(innerRadius, 1.0, 0.5), len);

    float3 colBase = mix(baseColor1, baseColor2, cl);

    // bgLuminance == 0 → dark variant only.
    // `boost` (0..1, smoothed audio level from the view model) brightens
    // the ring + hotspot when the user / AI is speaking. Tuned conservative
    // (×0.7) so loud voice doesn't blow out the visual.
    float gain = 1.0 + boost * 0.7;
    float3 darkCol = mix(baseColor3, colBase * gain, v0);
    darkCol = (darkCol + v1 * gain) * v2 * v3;
    darkCol = clamp(darkCol, 0.0, 1.0);

    // extractAlpha: alpha = max channel; unpremultiply rgb.
    float aOut = max(max(darkCol.r, darkCol.g), darkCol.b);
    float3 rgb = darkCol / (aOut + 1e-5);

    // SwiftUI compositor expects pre-multiplied alpha from .colorEffect.
    return half4(half3(rgb) * half(aOut), half(aOut));
}
