// CanvasShaders.metal
// Minimal fullscreen-triangle blit that draws a pixel-art canvas texture with
// nearest-neighbour sampling (no interpolation, so pixels stay crisp).

#include <metal_stdlib>
using namespace metal;

struct CanvasVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CanvasVertexOut canvas_vertex(uint vid [[vertex_id]]) {
    // Fullscreen triangle covering the clip space with a single draw call.
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 uvs[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    CanvasVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 canvas_fragment(CanvasVertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}
