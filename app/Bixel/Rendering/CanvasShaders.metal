// CanvasShaders.metal
// Infinite-canvas renderer. One fullscreen triangle shades the whole viewport:
// dark workspace, drop shadow, a bounded artboard with a transparency
// checkerboard, the canvas texture (nearest-neighbour, pixels stay crisp),
// an optional onion-skin texture underneath, a pixel grid at high zoom, and
// a hairline artboard border. All geometry arrives via ViewportUniforms, so
// pan/zoom never touches the CPU-side pixel buffers.

#include <metal_stdlib>
using namespace metal;

struct ViewportUniforms {
    float2 viewSize;    // drawable size in device px
    float2 canvasSize;  // document size in px
    float2 origin;      // artboard bottom-left corner, y-up device px
    float  scale;       // device px per document px
    float  gridAlpha;   // 0 = hidden, 1 = shown
    float  onionAlpha;  // 0 = off, >0 = previous-frame ghost opacity
    float  pad;
};

struct CanvasVertexOut {
    float4 position [[position]];
};

vertex CanvasVertexOut canvas_vertex(uint vid [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    CanvasVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    return out;
}

static inline float3 over(float3 dst, float4 src) {
    return src.rgb * src.a + dst.rgb * (1.0 - src.a);
}

fragment float4 canvas_fragment(CanvasVertexOut in [[stage_in]],
                                constant ViewportUniforms& u [[buffer(0)]],
                                texture2d<float> tex [[texture(0)]],
                                texture2d<float> prevTex [[texture(1)]],
                                sampler smp [[sampler(0)]]) {
    // Fragment position is top-left origin; the viewport math is y-up.
    float2 p = float2(in.position.x, u.viewSize.y - in.position.y);
    float2 local = p - u.origin;
    float2 board = u.canvasSize * u.scale;

    bool inside = local.x >= 0.0 && local.y >= 0.0 && local.x < board.x && local.y < board.y;

    // Distance from this fragment to the artboard rectangle.
    float2 e = max(max(-local, local - board), float2(0.0));
    float outsideDist = length(e);

    if (!inside) {
        // Endless workspace with a soft drop shadow hugging the artboard and a
        // hairline border.
        float3 bg = float3(0.070, 0.073, 0.085);
        float shadow = (1.0 - smoothstep(0.0, 16.0, outsideDist)) * 0.45;
        bg *= 1.0 - shadow;
        if (outsideDist <= 1.0) {
            bg = mix(bg, float3(1.0), 0.30);
        }
        return float4(bg, 1.0);
    }

    // Transparency checkerboard (fixed screen-size cells, Photoshop-style).
    float cell = 9.0;
    float parity = fmod(floor(local.x / cell) + floor(local.y / cell), 2.0);
    float3 col = mix(float3(0.545), float3(0.400), parity);

    // Texture v: local.y = board height is the top edge, texture row 0.
    float2 uv = float2(local.x / board.x, 1.0 - local.y / board.y);

    if (u.onionAlpha > 0.0) {
        float4 prev = prevTex.sample(smp, uv);
        prev.a *= u.onionAlpha;
        col = over(col, prev);
    }

    float4 cur = tex.sample(smp, uv);
    col = over(col, cur);

    // Pixel grid once individual document pixels are big enough to see.
    if (u.gridAlpha > 0.0 && u.scale >= 6.0) {
        float2 g = fract(local / u.scale);
        float2 d = min(g, 1.0 - g) * u.scale;
        float line = 1.0 - smoothstep(0.0, 1.25, min(d.x, d.y));
        col = mix(col, float3(1.0), line * u.gridAlpha * 0.16);
    }

    // Inner edge of the hairline border.
    float edgeDist = min(min(local.x, local.y), min(board.x - local.x, board.y - local.y));
    if (edgeDist < 1.0) {
        col = mix(col, float3(1.0), 0.30);
    }

    return float4(col, 1.0);
}
