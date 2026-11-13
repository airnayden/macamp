/// Embedded Metal Shading Language source for the cross-platform visualizer.
///
/// The shaders are compiled at runtime via `device.makeLibrary(source:)` rather
/// than shipped as a `.metal` resource. This is deliberate: a loose `.metal`
/// file in the SPM target trips an "unhandled resource" warning that
/// `Package.swift` cannot suppress, and runtime compilation sidesteps the
/// separately-downloadable Xcode Metal Toolchain (see Task 7 learnings).
///
/// `VizUniforms` below MUST stay byte-compatible with the Swift `VizUniforms`
/// in `MetalRenderer.swift`. Buffer bindings: bars=0, waveform=1, particles=2,
/// uniforms=3 (bound to both the vertex and fragment stages).
enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VizUniforms {
        float2 resolution;
        float time;
        uint motionEnabled;
        uint barCount;
        uint waveCount;
        uint particleCount;
        float4 accent;
        float4 background;
    };

    struct VizParticle {
        float2 position;
        float size;
        float intensity;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Fullscreen triangle generated from the vertex id — no vertex buffer.
    // uv is in 0...1 with the origin at the bottom-left.
    vertex VertexOut viz_vertex(uint vid [[vertex_id]],
                                constant VizUniforms& u [[buffer(3)]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        float2 pos = positions[vid];
        VertexOut out;
        out.position = float4(pos, 0.0, 1.0);
        out.uv = pos * 0.5 + 0.5;
        return out;
    }

    fragment float4 frag_bars(VertexOut in [[stage_in]],
                              constant float* bars [[buffer(0)]],
                              constant VizUniforms& u [[buffer(3)]]) {
        uint count = max(u.barCount, 1u);
        uint index = min(uint(in.uv.x * float(count)), count - 1u);
        float height = bars[index];
        // Thin gap between bars for definition.
        float column = fract(in.uv.x * float(count));
        float gap = smoothstep(0.0, 0.06, column) * smoothstep(0.0, 0.06, 1.0 - column);
        float lit = step(in.uv.y, height) * gap;
        float3 col = mix(u.background.rgb, u.accent.rgb, lit);
        return float4(col, 1.0);
    }

    fragment float4 frag_oscilloscope(VertexOut in [[stage_in]],
                                      constant float* waveform [[buffer(1)]],
                                      constant VizUniforms& u [[buffer(3)]]) {
        uint count = max(u.waveCount, 1u);
        uint index = min(uint(in.uv.x * float(count)), count - 1u);
        float centered = waveform[index] * 0.5 + 0.5;
        float dist = abs(in.uv.y - centered);
        float line = 1.0 - smoothstep(0.0, 0.02, dist);
        float3 col = mix(u.background.rgb, u.accent.rgb, line);
        return float4(col, 1.0);
    }

    fragment float4 frag_particles(VertexOut in [[stage_in]],
                                   constant VizParticle* particles [[buffer(2)]],
                                   constant VizUniforms& u [[buffer(3)]]) {
        float3 col = u.background.rgb;
        uint count = u.particleCount;
        for (uint i = 0u; i < count; i++) {
            VizParticle p = particles[i];
            float dist = distance(in.uv, p.position);
            float radius = p.size * 0.05 + 0.004;
            float glow = (1.0 - smoothstep(0.0, radius, dist)) * p.intensity;
            col += u.accent.rgb * glow;
        }
        return float4(min(col, 1.0), 1.0);
    }

    fragment float4 frag_aurora(VertexOut in [[stage_in]],
                                constant float* bars [[buffer(0)]],
                                constant VizUniforms& u [[buffer(3)]]) {
        uint count = max(u.barCount, 1u);
        float energy = 0.0;
        for (uint i = 0u; i < count; i++) {
            energy += bars[i];
        }
        energy /= float(count);
        float t = u.time * float(u.motionEnabled);
        float wave = sin(in.uv.x * 6.2831853 + t) * 0.5 + 0.5;
        float band = sin(in.uv.x * 12.0 + t * 1.3) * 0.1 * energy;
        float center = 0.5 + band + wave * 0.2 * energy;
        float dist = abs(in.uv.y - center);
        float glow = (1.0 - smoothstep(0.0, 0.3, dist)) * (0.25 + energy);
        float3 col = mix(u.background.rgb, u.accent.rgb, glow);
        return float4(col, 1.0);
    }
    """
}
