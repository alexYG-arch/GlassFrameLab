import Foundation

/// Optional optical modulation. It does not change base material parameters.
enum BorderFlowShader {
    static let source = """
    float3 flowToSRGB(float3 c) {
        return select(12.92*c, 1.055*pow(max(c,0.0),float3(1.0/2.4))-.055, c > .0031308);
    }
    float3 flowToLinear(float3 c) {
        return select(c/12.92, pow((c+.055)/1.055,float3(2.4)), c > .04045);
    }

    // Preserve sRGB HSV hue: only value and saturation change with background.
    // The base glass and its dark-adaptation coefficient are never modified.
    float3 adaptFlowColor(float3 linearColor, float amount) {
        if (amount <= 0) return linearColor;
        float3 c = flowToSRGB(linearColor);
        float hi = max(c.r,max(c.g,c.b)), lo = min(c.r,min(c.g,c.b));
        float span = hi-lo;
        float saturation = hi > .00001 ? span/hi : 0;
        float value = hi * mix(1.0,.92,amount);
        float nextSaturation = min(1.0,saturation*mix(1.0,1.615751,amount));
        float3 huePosition = span > .00001 ? (c-lo)/span : float3(1);
        c = value * ((1-nextSaturation)+nextSaturation*huePosition);
        return flowToLinear(c);
    }

    // Match the premultiplied sRGB surface consumed by the window compositor.
    // Encoding a linear-premultiplied colored halo instead would brighten a
    // white backdrop between the line and the neutral outer diffusion.
    float4 lightFlowOver(float4 base, float3 linearColor, float4 flow,
                         float coverage) {
        // Light uses only the soft inward mapping. Keep the base rim untouched
        // where there is no mapping; the caller fades the dark line with the
        // existing continuous background-adaptation coefficient.
        if (flow.y*coverage <= 0) return base;
        // Clamp before the arc fade: the legacy edge can encode RGB > alpha.
        // Clamping after blending clips only the upper fading pixels to white.
        float3 rgb = min(flowToSRGB(base.rgb),float3(base.a));
        float alpha = base.a;
        float3 color = flowToSRGB(linearColor);
        // Coverage correction and color use the same arc fade. No separate
        // inward contact stripe may outlive the full line cross-section.
        // No additional neutral shade in the light flow; base shading is intact.
        float spill = clamp(flow.y*coverage,0.0,1.0);
        rgb = color*spill + rgb*(1-spill);
        alpha = spill + alpha*(1-spill);
        // The sRGB render target encodes this value once on write.
        return float4(flowToLinear(clamp(rgb,0.0,alpha)),alpha);
    }

    float contourProgress(float2 p, float2 size, float radius) {
        float r = max(radius, .001);
        float a = max(0.0, size.x - 2*r), b = max(0.0, size.y - 2*r);
        float c = M_PI_F * r * .5;
        float s;
        if (p.x > size.x-r && p.y < r)
            s = a + r * (atan2(p.y-r, p.x-size.x+r) + M_PI_F*.5);
        else if (p.x > size.x-r && p.y > size.y-r)
            s = a+c+b + r * atan2(p.y-size.y+r, p.x-size.x+r);
        else if (p.x < r && p.y > size.y-r)
            s = 2*a+2*c+b + r * (atan2(p.y-size.y+r, p.x-r) - M_PI_F*.5);
        else if (p.x < r && p.y < r) {
            float angle = atan2(p.y-r, p.x-r);
            if (angle < 0) angle += 2*M_PI_F;
            s = 2*a+3*c+2*b + r * (angle - M_PI_F);
        } else {
            float2 q = abs(p-size*.5) - (size*.5-r);
            if (q.y >= q.x) s = p.y < size.y*.5 ? p.x-r : a+2*c+b+size.x-r-p.x;
            else s = p.x > size.x*.5 ? a+c+p.y-r : 2*a+3*c+b+size.y-r-p.y;
        }
        return fract(s / max(2*a+2*b+4*c, .001));
    }

    // x=edge contribution, y=soft inward spill, z=diffuse shade, w=tail fraction.
    float4 borderFlow(float2 position, float2 size, float radius, float distance,
                      float aa, float4 flow, float4 optics) {
        if (flow.w <= 0 || abs(distance) > optics.z*4) return float4(0);
        float u = contourProgress(position, size, radius);
        float behind = fract(flow.x - flow.z*u);
        // Signed arc distance gives the leading side the head color, not the purple tail.
        float signedBehind = behind > .5 ? behind-1 : behind;
        float t = clamp(signedBehind / flow.y, 0.0, 1.0);
        float trail = pow(1.0-smoothstep(0.0, 1.0, t), 2.0);
        float perimeter = 2*(size.x+size.y-4*radius) + 2*M_PI_F*radius;
        // Fade the line head over a short arc length; the inward optical spill
        // keeps its separate, broader diffusion envelope.
        float headFade = min(6.0 / max(perimeter, .001), flow.y * .15);
        float edgeEnvelope = trail * smoothstep(-headFade, headFade, signedBehind);
        float depth = max(-distance, 0.0);
        float spread = optics.z * mix(.55, 1.0, trail);
        float lead = spread * (1.5 + .5*depth/spread) / max(perimeter, .001);
        float softEnvelope = trail * smoothstep(-lead, lead, signedBehind);
        float spill = softEnvelope * optics.x * mix(1.0,.75,optics.w) * exp(-pow(depth/spread, 2.0));
        float shade = softEnvelope * optics.y * exp(-pow(depth/(spread*1.7), 2.0)) * (1-exp(-depth/spread));
        // Geometry and arc envelopes are identical on light and dark backgrounds.
        float lineWidth = max(aa*.75, .3);
        float edge = edgeEnvelope * exp(-pow(distance / lineWidth, 2.0));
        return float4(edge, spill, shade, t) * float4(flow.w,flow.w,flow.w,1);
    }
    """
}
