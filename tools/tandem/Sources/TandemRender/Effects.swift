import CoreImage
import Foundation
import TandemCore
import TandemMedia

/// Applies effects from `EffectRegistry` to a layer.
///
/// Colour and utility effects run in the source's own pixels, in list order,
/// after the media's look. The style effects (rounded corners, border, drop
/// shadow) have fixed places in the layer pipeline instead, because they
/// depend on the crop, the cutout and the transform.
///
/// Sizes marked `px@1080` are output pixels at 1080p: `pixelsPerUnit`
/// converts them to the pixels of the image being processed, so a blur looks
/// the same whatever the layer's scale.
struct EffectEnvironment {
    var registry: EffectRegistry
    var folder: ProjectFolder
    /// Pixels of the image being processed per px@1080 unit.
    var pixelsPerUnit: CGFloat
}

enum EffectRenderer {
    static let styleTypes: Set<String> = ["dropShadow", "border", "roundedCorners"]

    /// Runs every enabled colour or utility effect in order.
    static func apply(_ effects: [Effect], to image: CIImage, _ env: EffectEnvironment) -> CIImage {
        var out = image
        for effect in effects where effect.enabled && !styleTypes.contains(effect.type) {
            guard let definition = env.registry.definition(effect.type), definition.domain == .video else { continue }
            out = apply(effect.type, definition, definition.resolvedParams(effect), to: out, env)
        }
        return out
    }

    /// The resolved parameters of the first enabled style effect of a type.
    static func style(_ type: String, in effects: [Effect], _ registry: EffectRegistry) -> [String: ParamValue]? {
        guard let effect = effects.first(where: { $0.type == type && $0.enabled }),
              let definition = registry.definition(type) else { return nil }
        return definition.resolvedParams(effect)
    }

    static func apply(_ type: String, _ definition: EffectDefinition, _ params: [String: ParamValue], to image: CIImage, _ env: EffectEnvironment) -> CIImage {
        func number(_ key: String) -> Double { params[key]?.number ?? definition.param(key)?.defaultValue.number ?? 0 }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }

        switch type {
        case "colorAdjust":
            guard let kernel = Kernels.colorAdjust else { return image }
            let a = CIVector(x: number("exposure"), y: number("contrast") / 100, z: number("blackLevel") / 100, w: number("highlights") / 100)
            let b = CIVector(x: number("shadows") / 100, y: number("saturation") / 100, z: number("vibrance") / 100, w: number("temperature") / 100)
            let c = CIVector(x: number("tint") / 100, y: 0, z: 0, w: 0)
            return kernel.apply(extent: extent, arguments: [image, a, b, c]) ?? image

        case "hsl":
            guard let kernel = Kernels.hsl else { return image }
            let colours = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
            func vectors(_ suffix: String) -> [CIVector] {
                let v = colours.map { CGFloat(number($0 + suffix) / 100) }
                return [CIVector(x: v[0], y: v[1], z: v[2], w: v[3]), CIVector(x: v[4], y: v[5], z: v[6], w: v[7])]
            }
            let values = colours.flatMap { c in ["Hue", "Saturation", "Luminance"].map { number(c + $0) } }
            if values.allSatisfy({ $0 == 0 }) { return image }
            return kernel.apply(extent: extent, arguments: [image] + vectors("Hue") + vectors("Saturation") + vectors("Luminance")) ?? image

        case "vignette":
            guard let kernel = Kernels.vignette else { return image }
            let amount = number("amount") / 100
            if amount == 0 { return image }
            // Radii as fractions of the centre-to-corner distance: `size` is
            // the clear middle, `feather` how gradually it falls off.
            let inner = 0.2 + 0.6 * number("size") / 100
            let feather = 0.1 + 0.9 * number("feather") / 100
            let corner = extent.height / 2 * sqrt(2)
            guard let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": inner * corner,
                "inputRadius1": (inner + feather) * corner,
                "inputColor0": CIColor.black,
                "inputColor1": CIColor.white
            ])?.outputImage else { return image }
            // Stretched to the frame's aspect, so the fall-off is elliptical.
            let ellipse = mask
                .transformed(by: CGAffineTransform(scaleX: extent.width / extent.height, y: 1))
                .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
                .cropped(to: extent)
            return kernel.apply(extent: extent, arguments: [image, ellipse, amount]) ?? image

        case "sharpen":
            let amount = number("amount")
            if amount <= 0 { return image }
            // Sharpening is about source detail, so the radius follows the
            // source resolution rather than the output.
            let radius = 1.69 * max(1, extent.height / 1080)
            return image.clampedToExtent()
                .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": amount / 10, "inputRadius": radius])
                .cropped(to: extent)

        case "lut":
            guard case .string(let path)? = params["path"], !path.isEmpty,
                  let lut = LUTCache.shared.lut(at: env.folder.url(forPath: path)) else { return image }
            let intensity = min(max(number("intensity"), 0), 1)
            if intensity == 0 { return image }
            let graded = lut.apply(to: image).cropped(to: extent)
            if intensity >= 1 { return graded }
            return image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: graded, kCIInputTimeKey: intensity
            ]).cropped(to: extent)

        default:
            guard let binding = definition.coreImage else { return image }
            return applyBinding(binding, definition, params, to: image, env)
        }
    }

    /// Any effect that names a Core Image filter: parameters map onto filter
    /// inputs, and px@1080 values are converted to image pixels.
    static func applyBinding(_ binding: CoreImageBinding, _ definition: EffectDefinition, _ params: [String: ParamValue], to image: CIImage, _ env: EffectEnvironment) -> CIImage {
        guard let filter = CIFilter(name: binding.filter) else { return image }
        let keys = Set(filter.inputKeys)
        let extent = image.extent
        guard keys.contains(kCIInputImageKey) else { return image }
        // Clamping first keeps blurs from fading to transparent at the edges.
        filter.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        for (param, inputKey) in binding.inputs where keys.contains(inputKey) {
            guard let value = params[param] else { continue }
            switch value {
            case .number(let n):
                let scaled = definition.param(param)?.unit == "px@1080" ? n * Double(env.pixelsPerUnit) : n
                filter.setValue(scaled, forKey: inputKey)
            case .bool(let b):
                filter.setValue(b, forKey: inputKey)
            case .string(let s):
                filter.setValue(s, forKey: inputKey)
            case .color(let c):
                filter.setValue(CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a), forKey: inputKey)
            case .point(let p):
                // Points are fractions of the image, y down.
                filter.setValue(CIVector(x: extent.minX + p.x * extent.width, y: extent.maxY - p.y * extent.height), forKey: inputKey)
            }
        }
        for (key, value) in binding.constants where keys.contains(key) {
            filter.setValue(value, forKey: key)
        }
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Style effects

    /// Rounds the corners of the (cropped) layer.
    static func roundedCorners(_ image: CIImage, radius: CGFloat) -> CIImage {
        let extent = image.extent
        guard radius > 0, !extent.isEmpty else { return image }
        let r = min(radius, min(extent.width, extent.height) / 2)
        guard let mask = roundedRect(extent, radius: r, color: .white) else { return image }
        return image.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
    }

    /// An outline around the layer. Rectangles get a crisp procedural frame
    /// (following rounded corners); cut-out layers get an outline that
    /// follows the person.
    static func border(_ image: CIImage, width: CGFloat, color: RGBA, cornerRadius: CGFloat, followsAlpha: Bool) -> CIImage {
        let extent = image.extent
        guard width > 0, !extent.isEmpty else { return image }
        let colour = CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        if !followsAlpha {
            let outer = extent.insetBy(dx: -width, dy: -width)
            let radius = cornerRadius > 0 ? cornerRadius + width : 0
            guard let frame = roundedRect(outer, radius: radius, color: colour) else { return image }
            return image.composited(over: frame)
        }
        let grown = image.clampedToExtent().cropped(to: extent.insetBy(dx: -width * 2, dy: -width * 2))
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": width])
        let outline = CIImage(color: colour).cropped(to: grown.extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: grown])
        return image.composited(over: outline)
    }

    /// A soft shadow behind the layer that follows its alpha (so it follows
    /// a cutout). `angle` is where the light comes from, degrees
    /// anticlockwise from the right, so 135 casts the shadow down and right.
    static func dropShadow(_ image: CIImage, distance: CGFloat, angle: Double, blur: CGFloat, opacity: Double, color: RGBA) -> CIImage {
        let extent = image.extent
        guard opacity > 0, !extent.isEmpty else { return image }
        let colour = CIColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        var shadow = CIImage(color: colour).cropped(to: extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: image])
        if blur > 0 {
            shadow = shadow.applyingGaussianBlur(sigma: Double(blur))
        }
        let radians = angle * .pi / 180
        shadow = shadow
            .transformed(by: CGAffineTransform(translationX: -distance * CGFloat(cos(radians)), y: -distance * CGFloat(sin(radians))))
            .tandemOpacity(min(opacity, 1) * color.a)
        return image.composited(over: shadow)
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage? {
        if radius <= 0 { return CIImage(color: color).cropped(to: rect) }
        return CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": color
        ])?.outputImage
    }
}
