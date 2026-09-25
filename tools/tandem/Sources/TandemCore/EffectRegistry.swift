import Foundation

/// Describes an effect: its parameters, ranges and defaults. The inspector
/// builds its controls from these, `tandem effects` prints them for agents,
/// and the renderer reads defaults for any parameter a clip doesn't set.
///
/// Effects are data. A pack can add one with a JSON file; if it names a
/// Core Image filter in `coreImage`, it renders with no Swift changes.
public struct EffectDefinition: Codable, Equatable, Sendable {
    public enum Domain: String, Codable, Sendable { case video, audio }

    public var type: String
    public var name: String
    public var category: String
    public var domain: Domain
    public var summary: String
    public var params: [ParamDefinition]
    public var coreImage: CoreImageBinding?

    public init(
        type: String,
        name: String,
        category: String,
        domain: Domain,
        summary: String,
        params: [ParamDefinition],
        coreImage: CoreImageBinding? = nil
    ) {
        self.type = type
        self.name = name
        self.category = category
        self.domain = domain
        self.summary = summary
        self.params = params
        self.coreImage = coreImage
    }

    public func param(_ key: String) -> ParamDefinition? {
        params.first { $0.key == key }
    }

    /// Every parameter with its default filled in, then the effect's own
    /// values on top.
    public func resolvedParams(_ effect: Effect) -> [String: ParamValue] {
        var values = Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) })
        for (key, value) in effect.params { values[key] = value }
        return values
    }
}

public struct ParamDefinition: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case number, bool, color, point, choice, string }

    public var key: String
    public var name: String
    public var kind: Kind
    public var defaultValue: ParamValue
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var unit: String?
    public var choices: [String]?
    public var animatable: Bool

    public init(
        _ key: String,
        _ name: String,
        kind: Kind = .number,
        default defaultValue: ParamValue,
        min: Double? = nil,
        max: Double? = nil,
        step: Double? = nil,
        unit: String? = nil,
        choices: [String]? = nil,
        animatable: Bool = true
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.step = step
        self.unit = unit
        self.choices = choices
        self.animatable = animatable
    }
}

/// Maps an effect onto one Core Image filter: parameter keys to filter input
/// keys, plus constant inputs.
public struct CoreImageBinding: Codable, Equatable, Sendable {
    public var filter: String
    public var inputs: [String: String]
    public var constants: [String: Double]

    public init(filter: String, inputs: [String: String], constants: [String: Double] = [:]) {
        self.filter = filter
        self.inputs = inputs
        self.constants = constants
    }
}

public struct EffectRegistry: Sendable {
    public private(set) var definitions: [String: EffectDefinition]

    public init(_ definitions: [EffectDefinition]) {
        self.definitions = Dictionary(definitions.map { ($0.type, $0) }, uniquingKeysWith: { _, new in new })
    }

    public func definition(_ type: String) -> EffectDefinition? {
        definitions[type]
    }

    public var sorted: [EffectDefinition] {
        definitions.values.sorted { ($0.category, $0.name) < ($1.category, $1.name) }
    }

    public mutating func register(_ definition: EffectDefinition) {
        definitions[definition.type] = definition
    }

    /// Adds every `*.json` effect definition in a folder (one definition or
    /// an array per file). Returns the types it loaded.
    @discardableResult
    public mutating func loadDefinitions(in folder: URL) throws -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [String] = []
        for file in files where file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            if let many = try? decoder.decode([EffectDefinition].self, from: data) {
                many.forEach { register($0) }
                loaded += many.map(\.type)
            } else {
                let one = try decoder.decode(EffectDefinition.self, from: data)
                register(one)
                loaded.append(one.type)
            }
        }
        return loaded
    }

    /// The built-in effects, chosen from what Mike used in 51 Filmora
    /// projects: the camera grade (contrast, black level, temperature, red
    /// saturation, vignette, sharpen), the PiP drop shadow and border, and
    /// a few utilities. No colour wheels or curves; he never touched them.
    public static let standard = EffectRegistry(builtIn)

    public static let builtIn: [EffectDefinition] = [
        EffectDefinition(
            type: "colorAdjust",
            name: "Colour",
            category: "Colour",
            domain: .video,
            summary: "Exposure, contrast, black level, saturation and white balance.",
            params: [
                ParamDefinition("exposure", "Exposure", default: .number(0), min: -3, max: 3, step: 0.05, unit: "stops"),
                ParamDefinition("contrast", "Contrast", default: .number(0), min: -100, max: 100, step: 1),
                ParamDefinition("blackLevel", "Black level", default: .number(0), min: -100, max: 100, step: 1),
                ParamDefinition("highlights", "Highlights", default: .number(0), min: -100, max: 100, step: 1),
                ParamDefinition("shadows", "Shadows", default: .number(0), min: -100, max: 100, step: 1),
                ParamDefinition("saturation", "Saturation", default: .number(0), min: -100, max: 100, step: 1),
                ParamDefinition("vibrance", "Vibrance", default: .number(0), min: -100, max: 100, step: 1),
                ParamDefinition("temperature", "Temperature", default: .number(0), min: -100, max: 100, step: 1),
                ParamDefinition("tint", "Tint", default: .number(0), min: -100, max: 100, step: 1)
            ]
        ),
        EffectDefinition(
            type: "hsl",
            name: "HSL",
            category: "Colour",
            domain: .video,
            summary: "Saturation per colour range. Mike's camera grade pulls reds down 7 or 8 to calm skin.",
            params: ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"].flatMap { colour in
                [
                    ParamDefinition("\(colour)Hue", "\(colour.capitalized) hue", default: .number(0), min: -100, max: 100, step: 1),
                    ParamDefinition("\(colour)Saturation", "\(colour.capitalized) saturation", default: .number(0), min: -100, max: 100, step: 1),
                    ParamDefinition("\(colour)Luminance", "\(colour.capitalized) luminance", default: .number(0), min: -100, max: 100, step: 1)
                ]
            }
        ),
        EffectDefinition(
            type: "vignette",
            name: "Vignette",
            category: "Colour",
            domain: .video,
            summary: "Darkens the edges. Mike's camera grade uses -22 to -37.",
            params: [
                ParamDefinition("amount", "Amount", default: .number(-30), min: -100, max: 100, step: 1),
                ParamDefinition("size", "Size", default: .number(50), min: 0, max: 100, step: 1),
                ParamDefinition("feather", "Feather", default: .number(50), min: 0, max: 100, step: 1)
            ]
        ),
        EffectDefinition(
            type: "sharpen",
            name: "Sharpen",
            category: "Colour",
            domain: .video,
            summary: "Luma sharpening. Mike uses 3 or 4.",
            params: [
                ParamDefinition("amount", "Amount", default: .number(3), min: 0, max: 10, step: 0.5)
            ]
        ),
        EffectDefinition(
            type: "lut",
            name: "LUT",
            category: "Colour",
            domain: .video,
            summary: "Applies a .cube lookup table.",
            params: [
                ParamDefinition("path", "File", kind: .string, default: .string(""), animatable: false),
                ParamDefinition("intensity", "Intensity", default: .number(1), min: 0, max: 1, step: 0.01)
            ]
        ),
        EffectDefinition(
            type: "dropShadow",
            name: "Drop shadow",
            category: "Style",
            domain: .video,
            summary: "Shadow behind the layer, following the cutout. Filmora's defaults: distance 4, blur 5, opacity 60.",
            params: [
                ParamDefinition("distance", "Distance", default: .number(4), min: 0, max: 100, step: 1, unit: "px@1080"),
                ParamDefinition("angle", "Angle", default: .number(135), min: 0, max: 360, step: 1, unit: "degrees"),
                ParamDefinition("blur", "Blur", default: .number(5), min: 0, max: 100, step: 1, unit: "px@1080"),
                ParamDefinition("opacity", "Opacity", default: .number(60), min: 0, max: 100, step: 1, unit: "%"),
                ParamDefinition("color", "Colour", kind: .color, default: .color(.black))
            ]
        ),
        EffectDefinition(
            type: "border",
            name: "Border",
            category: "Style",
            domain: .video,
            summary: "Outline around the layer, for the PiP frame.",
            params: [
                ParamDefinition("width", "Width", default: .number(4), min: 0, max: 60, step: 1, unit: "px@1080"),
                ParamDefinition("color", "Colour", kind: .color, default: .color(.white))
            ]
        ),
        EffectDefinition(
            type: "roundedCorners",
            name: "Rounded corners",
            category: "Style",
            domain: .video,
            summary: "Rounds the layer's corners.",
            params: [
                ParamDefinition("radius", "Radius", default: .number(24), min: 0, max: 500, step: 1, unit: "px@1080")
            ]
        ),
        EffectDefinition(
            type: "blur",
            name: "Blur",
            category: "Utility",
            domain: .video,
            summary: "Gaussian blur.",
            params: [
                ParamDefinition("radius", "Radius", default: .number(20), min: 0, max: 200, step: 1, unit: "px@1080")
            ],
            coreImage: CoreImageBinding(filter: "CIGaussianBlur", inputs: ["radius": "inputRadius"])
        ),
        EffectDefinition(
            type: "pixelate",
            name: "Pixelate",
            category: "Utility",
            domain: .video,
            summary: "Mosaic, for hiding keys and emails on screen.",
            params: [
                ParamDefinition("scale", "Block size", default: .number(24), min: 1, max: 200, step: 1, unit: "px@1080")
            ],
            coreImage: CoreImageBinding(filter: "CIPixellate", inputs: ["scale": "inputScale"])
        ),
        EffectDefinition(
            type: "pitchShift",
            name: "Pitch shift",
            category: "Audio",
            domain: .audio,
            summary: "Shifts pitch without changing speed.",
            params: [
                ParamDefinition("semitones", "Semitones", default: .number(0), min: -12, max: 12, step: 0.5)
            ]
        )
    ]
}
