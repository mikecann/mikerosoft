import Foundation

/// The geometry of the colour wheels effect (`colorWheels`), shared by the
/// renderer and the inspector so the puck, the ring and the picture agree.
///
/// Each wheel (shadows, midtones, highlights) has a hue in HSV degrees
/// (0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta), an amount
/// (how far its puck is from the centre, 100 at the edge) and a brightness
/// (-100 to 100).
///
/// The inspector lays a wheel out like a BT.709 vectorscope, as editors do:
/// Cb to the right and Cr up, so red sits at about 103 degrees and blue
/// just below the right. A hue pushes colours along the same line: its
/// direction is a change in R'G'B' with no BT.709 luma and one unit of
/// chroma, so moving a puck towards a colour moves that range towards it on
/// the scope without making it lighter or darker. Like the other colour
/// effects, this works on the encoded values with BT.709 luma weights.
public enum ColourWheels {
    public enum Wheel: String, CaseIterable, Sendable {
        case shadows, midtones, highlights

        public var hueKey: String { rawValue + "Hue" }
        public var amountKey: String { rawValue + "Amount" }
        public var brightnessKey: String { rawValue + "Brightness" }
        public var keys: [String] { [hueKey, amountKey, brightnessKey] }
        public var name: String { rawValue.capitalized }
    }

    /// Every parameter key, wheel by wheel.
    public static var keys: [String] { Wheel.allCases.flatMap(\.keys) }

    /// A colour or a change of colour, in encoded R'G'B'.
    public struct RGB: Equatable, Sendable {
        public var r: Double
        public var g: Double
        public var b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public static func * (v: RGB, k: Double) -> RGB { RGB(r: v.r * k, g: v.g * k, b: v.b * k) }
        public static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
    }

    /// BT.709 luma weights, as the Colour effect's kernel uses.
    public static let lumaWeights = RGB(r: 0.2126, g: 0.7152, b: 0.0722)
    /// BT.709 colour difference scales: Cb = (B' - Y') / 1.8556, Cr = (R' - Y') / 1.5748.
    public static let cbScale = 1.8556
    public static let crScale = 1.5748

    public static func luma(_ c: RGB) -> Double {
        lumaWeights.r * c.r + lumaWeights.g * c.g + lumaWeights.b * c.b
    }

    /// Cb and Cr of a colour (or of a change of colour).
    public static func chroma(_ c: RGB) -> (cb: Double, cr: Double) {
        let y = luma(c)
        return ((c.b - y) / cbScale, (c.r - y) / crScale)
    }

    /// Degrees in 0..<360.
    public static func normalised(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// The fully saturated colour of a hue: HSV with saturation and value 1.
    public static func rgb(hue: Double) -> RGB {
        let h = normalised(hue) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {
        case 0: return RGB(r: 1, g: x, b: 0)
        case 1: return RGB(r: x, g: 1, b: 0)
        case 2: return RGB(r: 0, g: 1, b: x)
        case 3: return RGB(r: 0, g: x, b: 1)
        case 4: return RGB(r: x, g: 0, b: 1)
        default: return RGB(r: 1, g: 0, b: x)
        }
    }

    /// The HSV hue of a colour or a change of colour, in degrees; nil for a
    /// grey (or no change), which has none.
    public static func hue(of c: RGB) -> Double? {
        let high = max(c.r, c.g, c.b)
        let low = min(c.r, c.g, c.b)
        let range = high - low
        guard range > 1e-12 else { return nil }
        let sector: Double
        if high == c.r {
            sector = (c.g - c.b) / range
        } else if high == c.g {
            sector = (c.b - c.r) / range + 2
        } else {
            sector = (c.r - c.g) / range + 4
        }
        return normalised(sector * 60)
    }

    /// Where a hue sits on a wheel: degrees anticlockwise from the right,
    /// as on a BT.709 vectorscope.
    public static func wheelAngle(hue: Double) -> Double {
        let c = chroma(rgb(hue: hue))
        return normalised(atan2(c.cr, c.cb) * 180 / .pi)
    }

    /// The hue at an angle on the wheel.
    public static func hue(wheelAngle: Double) -> Double {
        hue(of: direction(wheelAngle: wheelAngle)) ?? 0
    }

    /// The change that pushes towards the colour at an angle on the wheel:
    /// no luma, one unit of chroma.
    public static func direction(wheelAngle: Double) -> RGB {
        let radians = wheelAngle * .pi / 180
        let r = crScale * sin(radians)
        let b = cbScale * cos(radians)
        let g = -(lumaWeights.r * r + lumaWeights.b * b) / lumaWeights.g
        return RGB(r: r, g: g, b: b)
    }

    /// The change that pushes towards a hue: no luma, one unit of chroma.
    public static func direction(hue: Double) -> RGB {
        direction(wheelAngle: wheelAngle(hue: hue))
    }

    /// Where the puck sits for a hue and amount: x to the right, y up, and
    /// 1 from the centre at amount 100.
    public static func puck(hue: Double, amount: Double) -> (x: Double, y: Double) {
        let radians = wheelAngle(hue: hue) * .pi / 180
        let distance = amount / 100
        return (distance * cos(radians), distance * sin(radians))
    }

    /// The hue and amount for a puck position (x right, y up), kept inside
    /// the wheel. A puck in the middle keeps `hue`, so it doesn't jump.
    public static func hueAndAmount(x: Double, y: Double, keeping hue: Double = 0) -> (hue: Double, amount: Double) {
        let distance = min((x * x + y * y).squareRoot(), 1)
        guard distance > 1e-6 else { return (hue, 0) }
        let angle = normalised(atan2(y, x) * 180 / .pi)
        return (self.hue(wheelAngle: angle), distance * 100)
    }
}
