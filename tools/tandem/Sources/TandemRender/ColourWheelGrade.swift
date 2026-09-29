import CoreImage
import Foundation
import TandemCore

/// The colour wheels effect as per-channel lift, gain and gamma, the way
/// editors grade shadows, midtones and highlights:
///
///     y = x + lift * (1 - x)     shadows: moves black, leaves white
///     y = y * gain               highlights: moves white, leaves black
///     y = y ^ power              midtones: leaves black and white
///
/// A wheel's colour is `amount / 100` of its hue's direction (no luma, one
/// unit of chroma, see `ColourWheels`), so a puck changes the colour of its
/// range and not its brightness; the brightness slider moves all three
/// channels together. At amount 100 the shadows' black and the
/// highlights' white move by 0.1 of chroma, and mid grey moves about half
/// that for each wheel; brightness 100 lifts black by 0.15, raises white
/// by 25% or takes mid grey from 0.5 to 0.61.
public struct ColourWheelGrade: Equatable, Sendable {
    public var lift: ColourWheels.RGB
    public var gain: ColourWheels.RGB
    public var power: ColourWheels.RGB

    public static let liftColour = 0.10
    public static let liftBrightness = 0.15
    public static let gainColour = 0.10
    public static let gainBrightness = 0.25
    /// Midtone changes are in stops of the exponent: power = 2^-(colour + brightness).
    public static let gammaColour = 0.20
    public static let gammaBrightness = 0.50

    public static let neutral = ColourWheelGrade(
        lift: ColourWheels.RGB(r: 0, g: 0, b: 0),
        gain: ColourWheels.RGB(r: 1, g: 1, b: 1),
        power: ColourWheels.RGB(r: 1, g: 1, b: 1)
    )

    public init(lift: ColourWheels.RGB, gain: ColourWheels.RGB, power: ColourWheels.RGB) {
        self.lift = lift
        self.gain = gain
        self.power = power
    }

    /// The grade for the effect's parameters (missing ones are 0).
    public init(_ number: (String) -> Double) {
        func colour(_ wheel: ColourWheels.Wheel) -> ColourWheels.RGB {
            let amount = number(wheel.amountKey) / 100
            guard amount != 0 else { return ColourWheels.RGB(r: 0, g: 0, b: 0) }
            return ColourWheels.direction(hue: number(wheel.hueKey)) * amount
        }
        func all(_ value: Double) -> ColourWheels.RGB { ColourWheels.RGB(r: value, g: value, b: value) }

        let shadows = colour(.shadows) * Self.liftColour + all(number(ColourWheels.Wheel.shadows.brightnessKey) / 100 * Self.liftBrightness)
        let highlights = colour(.highlights) * Self.gainColour + all(1 + number(ColourWheels.Wheel.highlights.brightnessKey) / 100 * Self.gainBrightness)
        let midtones = colour(.midtones) * Self.gammaColour + all(number(ColourWheels.Wheel.midtones.brightnessKey) / 100 * Self.gammaBrightness)
        lift = shadows
        gain = highlights
        power = ColourWheels.RGB(r: exp2(-midtones.r), g: exp2(-midtones.g), b: exp2(-midtones.b))
    }

    public var isNeutral: Bool { self == .neutral }

    /// The grade on an image, as the renderer applies it (for previews
    /// outside a composition, like the effects library's tiles).
    public func apply(to image: CIImage) -> CIImage {
        guard !isNeutral, let kernel = Kernels.colorWheels, !image.extent.isInfinite else { return image }
        func vector(_ v: ColourWheels.RGB) -> CIVector { CIVector(x: v.r, y: v.g, z: v.b, w: 0) }
        return kernel.apply(extent: image.extent, arguments: [image, vector(lift), vector(gain), vector(power)]) ?? image
    }

    /// What the kernel does to one pixel (unpremultiplied), for tests and
    /// for anything that wants the numbers without a render.
    public func apply(_ x: ColourWheels.RGB) -> ColourWheels.RGB {
        func channel(_ v: Double, _ lift: Double, _ gain: Double, _ power: Double) -> Double {
            let y = (v + lift * (1 - v)) * gain
            return power == 1 ? y : (y < 0 ? -1 : 1) * pow(abs(y), power)
        }
        return ColourWheels.RGB(
            r: channel(x.r, lift.r, gain.r, power.r),
            g: channel(x.g, lift.g, gain.g, power.g),
            b: channel(x.b, lift.b, gain.b, power.b)
        )
    }
}
