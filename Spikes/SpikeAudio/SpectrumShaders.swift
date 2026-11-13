import Metal

// Xcode 26 ships the offline `metal` compiler as a separately downloadable "Metal
// Toolchain" component that isn't installed here, so build-time `.metal` compilation
// fails. We instead compile this source at RUNTIME via `device.makeLibrary(source:)`,
// which uses the Metal framework's own compiler (present on macOS AND the iOS
// simulator) and needs no toolchain.
let spectrumShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut spectrum_vertex(uint vid [[vertex_id]]) {
    float2 verts[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 p = verts[vid];
    VSOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2((p.x + 1.0) * 0.5, (p.y + 1.0) * 0.5);
    return out;
}

fragment float4 spectrum_fragment(VSOut in [[stage_in]],
                                  constant float *mags [[buffer(0)]],
                                  constant uint &count [[buffer(1)]]) {
    float x = clamp(in.uv.x, 0.0, 0.99999);
    float fb = x * float(count);
    uint bar = min(uint(fb), count - 1u);
    float within = fract(fb);
    float gap = step(0.06, within) * step(within, 0.94);
    float mag = clamp(mags[bar], 0.0, 1.0);
    float y = clamp(in.uv.y, 0.0, 1.0);
    float lit = step(y, mag) * gap;
    float3 low = float3(0.10, 0.85, 0.45);
    float3 high = float3(1.00, 0.25, 0.30);
    float3 barColor = mix(low, high, mag);
    float shade = (mag > 0.0) ? (0.45 + 0.55 * (1.0 - y / max(mag, 1e-3))) : 0.0;
    float3 background = float3(0.04, 0.04, 0.08);
    float3 color = mix(background, barColor * shade, lit);
    return float4(color, 1.0);
}
"""

func makeSpectrumLibrary(_ device: MTLDevice) throws -> MTLLibrary {
    try device.makeLibrary(source: spectrumShaderSource, options: nil)
}
