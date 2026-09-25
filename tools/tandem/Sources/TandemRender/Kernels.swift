import CoreImage
import Foundation
import Metal

/// Tandem's own Core Image kernels, written in Metal and compiled once at
/// runtime (`CIKernel.kernels(withMetalString:)`), so the package needs no
/// Metal build step. They run on the shared Metal-backed context.
///
/// All colour work happens on the encoded (gamma) values the way Filmora
/// and most editors do it: the render context has colour management off.
enum Kernels {
    static let header = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    """

    // Each kernel is compiled from its own source. When several stitchable
    // kernels come from one `kernels(withMetalString:)` call, Core Image
    // (macOS 26) runs whichever was used first for all of them.

    static let premultipliedScaleSource = header + """
    extern "C" { namespace coreimage {
    // Multiplies every channel of a premultiplied pixel: layer opacity.
    [[stitchable]] float4 tandemPremultipliedScale(sample_t s, float k) {
        return s * k;
    }
    }}
    """

    static let colorScaleSource = header + """
    extern "C" { namespace coreimage {
    // Multiplies colour but keeps alpha: fades to and from black.
    [[stitchable]] float4 tandemColorScale(sample_t s, float k) {
        return float4(s.rgb * k, s.a);
    }
    }}
    """

    static let colorAdjustSource = header + """
    namespace tandem {
        inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    }
    extern "C" { namespace coreimage {
    // The Colour effect in one pass. Sliders arrive as -1...1 (exposure in
    // stops): a = (exposure, contrast, black level, highlights),
    // b = (shadows, saturation, vibrance, temperature), c = (tint, 0, 0, 0).
    [[stitchable]] float4 tandemColorAdjust(sample_t s, float4 a, float4 b, float4 c) {
        float alpha = s.a;
        if (alpha <= 0.0) return s;
        float3 x = s.rgb / alpha;
        if (a.x != 0.0) {
            float3 linear = pow(max(x, 0.0), 2.2) * exp2(a.x);
            x = pow(linear, 1.0 / 2.2);
        }
        // Black level 7 lifts shadows by about 2%, as Filmora's does.
        float blackPoint = -a.z * 0.1;
        x = (x - blackPoint) / (1.0 - blackPoint);
        x = (x - 0.5) * (1.0 + a.y * 0.5) + 0.5;
        float l = tandem::luma(x);
        x += a.w * 0.25 * smoothstep(0.5, 1.0, l) + b.x * 0.25 * (1.0 - smoothstep(0.0, 0.5, l));
        l = tandem::luma(x);
        float chroma = clamp(max(max(x.r, x.g), x.b) - min(min(x.r, x.g), x.b), 0.0, 1.0);
        float saturation = (1.0 + b.y) * (1.0 + b.z * (1.0 - chroma));
        x = mix(float3(l), x, saturation);
        x *= float3(1.0 + 0.1 * b.w + 0.05 * c.x, 1.0 - 0.1 * c.x, 1.0 - 0.1 * b.w + 0.05 * c.x);
        x = clamp(x, 0.0, 1.0);
        return float4(x * alpha, alpha);
    }
    }}
    """

    static let hslSource = header + """
    namespace tandem {
        inline float3 rgbToHSL(float3 c) {
            float maxc = max(max(c.r, c.g), c.b);
            float minc = min(min(c.r, c.g), c.b);
            float l = (maxc + minc) * 0.5;
            float d = maxc - minc;
            if (d < 1e-6) { return float3(0.0, 0.0, l); }
            float s = l > 0.5 ? d / (2.0 - maxc - minc) : d / (maxc + minc);
            float h;
            if (maxc == c.r) { h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0); }
            else if (maxc == c.g) { h = (c.b - c.r) / d + 2.0; }
            else { h = (c.r - c.g) / d + 4.0; }
            return float3(h / 6.0, s, l);
        }

        inline float hueToRGB(float p, float q, float t) {
            t = fract(t);
            if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
            if (t < 0.5) return q;
            if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
            return p;
        }

        inline float3 hslToRGB(float3 hsl) {
            if (hsl.y < 1e-6) { return float3(hsl.z); }
            float q = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
            float p = 2.0 * hsl.z - q;
            return float3(hueToRGB(p, q, hsl.x + 1.0 / 3.0), hueToRGB(p, q, hsl.x), hueToRGB(p, q, hsl.x - 1.0 / 3.0));
        }
    }
    extern "C" { namespace coreimage {
    // Hue, saturation and lightness per colour range: red, orange, yellow,
    // green, aqua, blue, purple, magenta, centred at 0, 30, 60, 120, 180,
    // 240, 270 and 300 degrees. A pixel blends the two ranges its hue sits
    // between, and near-greys are left alone. Values are -1...1.
    [[stitchable]] float4 tandemHSL(sample_t s, float4 h0, float4 h1, float4 s0, float4 s1, float4 l0, float4 l1) {
        float alpha = s.a;
        if (alpha <= 0.0) return s;
        float3 x = clamp(s.rgb / alpha, 0.0, 1.0);
        float3 hsl = tandem::rgbToHSL(x);
        float centres[9] = {0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0, 360.0};
        float hues[8] = {h0.x, h0.y, h0.z, h0.w, h1.x, h1.y, h1.z, h1.w};
        float sats[8] = {s0.x, s0.y, s0.z, s0.w, s1.x, s1.y, s1.z, s1.w};
        float lums[8] = {l0.x, l0.y, l0.z, l0.w, l1.x, l1.y, l1.z, l1.w};
        float degrees = hsl.x * 360.0;
        int i = 0;
        for (int k = 1; k < 8; k++) { if (degrees >= centres[k]) { i = k; } }
        int j = (i + 1) % 8;
        float t = clamp((degrees - centres[i]) / (centres[i + 1] - centres[i]), 0.0, 1.0);
        float weight = smoothstep(0.02, 0.2, hsl.y);
        float dh = mix(hues[i], hues[j], t) * weight;
        float ds = mix(sats[i], sats[j], t) * weight;
        float dl = mix(lums[i], lums[j], t) * weight;
        hsl.x = fract(hsl.x + dh * (30.0 / 360.0) + 1.0);
        hsl.y = clamp(hsl.y * (1.0 + ds), 0.0, 1.0);
        hsl.z = clamp(hsl.z + dl * 0.2, 0.0, 1.0);
        x = tandem::hslToRGB(hsl);
        return float4(x * alpha, alpha);
    }
    }}
    """

    static let vignetteSource = header + """
    extern "C" { namespace coreimage {
    // Darkens (amount < 0) or lightens the edges, by a radial mask that is
    // 0 in the clear middle and 1 at full strength.
    [[stitchable]] float4 tandemVignette(sample_t s, sample_t m, float amount) {
        float alpha = s.a;
        if (alpha <= 0.0) return s;
        float t = smoothstep(0.0, 1.0, m.r);
        float3 x = s.rgb / alpha;
        if (amount < 0.0) { x *= 1.0 + amount * t; } else { x += (1.0 - x) * amount * t; }
        return float4(x * alpha, alpha);
    }
    }}
    """

    private static func compile(_ source: String, _ name: String) -> CIColorKernel? {
        do {
            return try CIKernel.kernels(withMetalString: source).first { $0.name == name } as? CIColorKernel
        } catch {
            NSLog("TandemRender: couldn't compile the \(name) kernel: \(error)")
            return nil
        }
    }

    static let premultipliedScale = compile(premultipliedScaleSource, "tandemPremultipliedScale")
    static let colorScale = compile(colorScaleSource, "tandemColorScale")
    static let colorAdjust = compile(colorAdjustSource, "tandemColorAdjust")
    static let hsl = compile(hslSource, "tandemHSL")
    static let vignette = compile(vignetteSource, "tandemVignette")
}

extension CIImage {
    /// Multiplies the layer, alpha included: opacity.
    func tandemOpacity(_ opacity: Double) -> CIImage {
        if opacity >= 1 { return self }
        if opacity <= 0 { return CIImage.empty() }
        if let kernel = Kernels.premultipliedScale, let out = kernel.apply(extent: extent, arguments: [self, Float(opacity)]) {
            return out
        }
        return applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(opacity), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(opacity), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(opacity), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])
    }

    /// Scales colour towards black, keeping alpha: dips to black.
    func tandemDarkened(_ amount: Double) -> CIImage {
        if amount >= 1 { return self }
        if let kernel = Kernels.colorScale, let out = kernel.apply(extent: extent, arguments: [self, Float(max(amount, 0))]) {
            return out
        }
        return applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(amount), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(amount), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(amount), w: 0)
        ])
    }
}
