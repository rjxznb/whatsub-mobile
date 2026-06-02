// OrbGlow.metal
//
// 1:1 port of the React-Bits Orb fragment shader
// (https://reactbits.dev/orb) to a SwiftUI `.colorEffect` stitchable
// function. THIS is the orb visual — the shader's bright noisy ring at
// r0≈0.6, dark inner area, and orbiting hotspot together make up the
// entire orb. No Liquid Glass or caustic layer on top.
//
// Deltas from the upstream shader:
//   • Hover distortion (`uv.x += hover * hoverIntensity * ...`) deleted
//     per the user's "no hover" requirement. There's no equivalent
//     touch-tracking input in a SwiftUI .colorEffect anyway.
//   • Background luminance hard-coded to 0 (QuickChat bg is solid black)
//     — collapses the light/dark branch in `draw()` to just the dark
//     variant.
//   • Two extra uniforms: `boost` (smoothed audio level — lifts the ring
//     and hotspot when there's voice) and `pressed` (1.0 while the user
//     is holding the orb — quadruples the hotspot orbit speed so the
//     press lands as immediate visual feedback).
//   • Pre-multiplied alpha output — what the SwiftUI compositor expects
//     from .colorEffect.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ---- noise helpers ----

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

// ---- palette (whatSub brand: violet / cyan-blue / deep navy) ----

constant float3 baseColor1 = float3(0.611765, 0.262745, 0.996078);  // violet
constant float3 baseColor2 = float3(0.298039, 0.760784, 0.913725);  // cyan-blue
constant float3 baseColor3 = float3(0.062745, 0.078431, 0.600000);  // deep navy
constant float  innerRadius = 0.6;
constant float  noiseScale  = 0.65;

[[stitchable]] half4 orbGlow(float2 position,
                             half4   /*existingColor*/,
                             float2  size,
                             float   time,
                             float   boost,
                             float   pressed)
{
    float2 center = size * 0.5;
    float  minDim = min(size.x, size.y);
    float2 uv     = (position - center) / minDim * 2.0;

    float ang    = atan2(uv.y, uv.x);
    float len    = length(uv);
    float invLen = len > 0.0 ? 1.0 / len : 0.0;

    // Outside the visible footprint → fully transparent.
    if (len > 1.10) return half4(0.0h);

    // ---- noisy bright ring (the orb's outer edge) ----
    float n0 = snoise3(float3(uv * noiseScale, time * 0.5)) * 0.5 + 0.5;
    float r0 = mix(mix(innerRadius, 1.0, 0.4),
                   mix(innerRadius, 1.0, 0.6),
                   n0);
    float d0 = distance(uv, (r0 * invLen) * uv);
    float v0 = light1(1.0, 10.0, d0);
    v0 *= smoothstep(r0 * 1.05, r0, len);

    // bgLuminance == 0 → use innerFade directly (no light-bg branch).
    float innerFade = smoothstep(r0 * 0.8, r0 * 0.95, len);
    v0 *= innerFade;

    // ---- angular color cycle ----
    float cl = cos(ang + time * 2.0) * 0.5 + 0.5;

    // ---- orbiting hotspot ----
    //
    // Base rate is -1.0 rad/s (one full orbit every 2π ≈ 6.3 s, CCW). While
    // the user is pressing the orb the rate scales 4× — instant visual
    // confirmation that the press registered.
    float rotRate = -1.0 * (1.0 + pressed * 3.0);
    float a       = time * rotRate;
    float2 pos    = float2(cos(a), sin(a)) * r0;
    float  d      = distance(uv, pos);
    float  v1     = light2(1.5, 5.0, d);
    v1 *= light1(1.0, 50.0, d0);

    // ---- alpha-shaping smoothsteps ----
    float v2 = smoothstep(1.0, mix(innerRadius, 1.0, n0 * 0.5), len);
    float v3 = smoothstep(innerRadius, mix(innerRadius, 1.0, 0.5), len);

    float3 colBase = mix(baseColor1, baseColor2, cl);

    // bgLuminance == 0 → dark-variant final composite only.
    // boost (0..1, smoothed voice level) lifts the ring + hotspot when
    // there's speech. Conservative ×0.6 so loud voice doesn't blow out.
    float gain    = 1.0 + boost * 0.6;
    float3 darkCol = mix(baseColor3, colBase * gain, v0);
    darkCol = (darkCol + v1 * gain) * v2 * v3;
    darkCol = clamp(darkCol, 0.0, 1.0);

    // extractAlpha + premultiply.
    float aOut = max(max(darkCol.r, darkCol.g), darkCol.b);
    float3 rgb = darkCol / (aOut + 1e-5);
    return half4(half3(rgb) * half(aOut), half(aOut));
}
