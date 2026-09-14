// Frozen from pre-adaptive source backup (2026-09-13). Do not regenerate from current code.

    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Params { float4 geometry; float4 crop; float4 layout; float4 edge; float4 tint; float4 light; float4 shadow; float4 inner; };
    vertex Vertex glassVertex(uint index [[vertex_id]]) {
        float2 p = float2((index << 1) & 2, index & 2);
        return { float4(p * float2(2, -2) + float2(-1, 1), 0, 1), p };
    }
    fragment float4 glassFragment(Vertex in [[stage_in]], texture2d<float> background [[texture(0)]], constant Params& p [[buffer(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 size = p.geometry.xy;
        float radius = p.geometry.w;
        float2 position = in.uv * (size + 2 * p.layout.x) - p.layout.x;
        float2 glassUV = position / size;
        float2 q = abs(position - size * .5) - (size * .5 - radius);
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float aa = 1.0 / p.geometry.z;
        float alpha = 1.0 - smoothstep(-aa, aa, distance);
        float falloff = 1.0 - smoothstep(0.0, p.layout.x, max(distance, 0.0));
        float shadowAlpha = p.layout.y * falloff * falloff * (1.0 - alpha);
        if (alpha <= 0.0) return float4(p.shadow.rgb * shadowAlpha, shadowAlpha);
        float3 color = background.sample(linearSampler, p.crop.xy + glassUV * p.crop.zw).rgb;
        float luminance = dot(color, float3(.2126, .7152, .0722));
        color = mix(float3(luminance), color, p.edge.z) + p.edge.w;
        color = mix(color, p.tint.rgb, p.tint.a);
        float2 normal = sign(position - size * .5) * max(q, 0.0);
        if (dot(normal, normal) < .0001) normal = q.x > q.y ? float2(sign(position.x-size.x*.5),0) : float2(0,sign(position.y-size.y*.5));
        float light = .5 + .5 * dot(normal / max(length(normal), .001), normalize(p.light.xy));
        float depth = max(-distance, 0.0);
        float width = max(.1, p.layout.w * mix(1.0, .55 + .9 * light, p.light.z));
        float glow = p.layout.z * mix(1.0, .25 + .75 * light, p.light.z) * exp(-depth / width) * smoothstep(.15, 1.2, depth);
        float shade = p.light.w * mix(1.0, .25 + .75 * (1.0-light), p.light.z) * exp(-depth / (width * 1.6)) * smoothstep(0.0, .7, depth);
        color = mix(color * (1.0-shade), p.inner.rgb, glow);
        float edge = 1.0 - smoothstep(max(0.0,p.edge.x-aa*.4), p.edge.x+aa*.4, depth);
        color = mix(color, float3(1), edge * p.edge.y * mix(1.0,.6+.4*light,p.light.z));
        return float4(clamp(color,0.0,1.0) * alpha + p.shadow.rgb * shadowAlpha, alpha + shadowAlpha);
    }
    