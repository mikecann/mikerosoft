import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// The colour wheels effect on colour patches, rendered through Core Image
/// in float so small moves and values outside 0...1 can be read exactly.
final class ColourWheelsRenderTests: XCTestCase {
    let folder = ProjectFolder(root: URL(fileURLWithPath: NSTemporaryDirectory()))

    /// A strip of patches, one pixel each, alpha 1. Each is a colour
    /// matrix's bias over black, because a `CIColor` clamps to 0...1.
    func strip(_ colours: [ColourWheels.RGB]) -> CIImage {
        var image = CIImage.empty()
        for (index, c) in colours.enumerated() {
            let patch = CIImage(color: .black).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: c.r, y: c.g, z: c.b, w: 0)
            ]).cropped(to: CGRect(x: index, y: 0, width: 1, height: 1))
            image = patch.composited(over: image)
        }
        return image
    }

    /// Renders patches through the effect and reads them back as floats.
    func run(_ params: [String: ParamValue], on colours: [ColourWheels.RGB], file: StaticString = #filePath, line: UInt = #line) -> [ColourWheels.RGB] {
        let env = EffectEnvironment(registry: .standard, folder: folder, pixelsPerUnit: 1)
        let out = EffectRenderer.apply([Effect(type: "colorWheels", params: params)], to: strip(colours), env)
        var data = [Float](repeating: .nan, count: colours.count * 4)
        RenderEngine.context.render(out, toBitmap: &data, rowBytes: colours.count * 16,
                                    bounds: CGRect(x: 0, y: 0, width: colours.count, height: 1), format: .RGBAf, colorSpace: nil)
        return colours.indices.map { i in
            ColourWheels.RGB(r: Double(data[i * 4]), g: Double(data[i * 4 + 1]), b: Double(data[i * 4 + 2]))
        }
    }

    func grey(_ v: Double) -> ColourWheels.RGB { ColourWheels.RGB(r: v, g: v, b: v) }

    func assertClose(_ a: ColourWheels.RGB, _ b: ColourWheels.RGB, _ tolerance: Double = 0.002, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let worst = max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
        XCTAssertLessThanOrEqual(worst, tolerance, "\(a) isn't \(b) \(message)", file: file, line: line)
    }

    /// Where a change of colour points on the BT.709 vectorscope, degrees.
    func angle(from a: ColourWheels.RGB, to b: ColourWheels.RGB) -> Double {
        let c = ColourWheels.chroma(ColourWheels.RGB(r: b.r - a.r, g: b.g - a.g, b: b.b - a.b))
        return ColourWheels.normalised(atan2(c.cr, c.cb) * 180 / .pi)
    }

    func angleGap(_ a: Double, _ b: Double) -> Double {
        let d = abs(ColourWheels.normalised(a) - ColourWheels.normalised(b))
        return min(d, 360 - d)
    }

    // MARK: -

    func testNeutralWheelsChangeNothing() {
        let patches = [ColourWheels.RGB(r: 0.2, g: 0.4, b: 0.6), grey(0), grey(1), ColourWheels.RGB(r: 1.2, g: -0.1, b: 0.5)]
        // Hues alone do nothing: the amount says how far.
        let out = run(["shadowsHue": .number(200), "midtonesHue": .number(40), "highlightsHue": .number(300)], on: patches)
        for (a, b) in zip(out, patches) { assertClose(a, b, 1e-3) }
        XCTAssertTrue(ColourWheelGrade { _ in 0 }.isNeutral)
    }

    func testShadowsTintTheDarksAndLeaveWhite() {
        let out = run(["shadowsHue": .number(240), "shadowsAmount": .number(50)], on: [grey(0.05), grey(0.3), grey(1)])
        // Blue in the darks, less of it higher up, none in white.
        XCTAssertGreaterThan(out[0].b - out[0].r, 0.08)
        XCTAssertLessThan(out[1].b - out[1].r, out[0].b - out[0].r)
        assertClose(out[2], grey(1), 1e-3)
        // The luma doesn't move.
        for (patch, v) in zip(out, [0.05, 0.3, 1]) {
            XCTAssertEqual(ColourWheels.luma(patch), v, accuracy: 0.002)
        }
    }

    func testHighlightsTintTheLightsAndLeaveBlack() {
        let out = run(["highlightsHue": .number(30), "highlightsAmount": .number(60)], on: [grey(0.8), grey(0.5), grey(0)])
        // Orange: red up, blue down.
        XCTAssertGreaterThan(out[0].r, out[0].g)
        XCTAssertGreaterThan(out[0].g, out[0].b)
        XCTAssertGreaterThan(out[0].r - out[0].b, out[1].r - out[1].b)
        assertClose(out[2], grey(0), 1e-4)
        XCTAssertEqual(ColourWheels.luma(out[0]), 0.8, accuracy: 0.002)
    }

    func testMidtonesTintMidGreyAndLeaveBlackAndWhite() {
        let out = run(["midtonesHue": .number(120), "midtonesAmount": .number(60)], on: [grey(0.5), grey(0), grey(1)])
        XCTAssertGreaterThan(out[0].g - out[0].r, 0.02)
        XCTAssertEqual(out[0].r, out[0].b, accuracy: 0.004)
        assertClose(out[1], grey(0), 1e-4)
        assertClose(out[2], grey(1), 1e-3)
        // Gamma keeps luma to first order.
        XCTAssertEqual(ColourWheels.luma(out[0]), 0.5, accuracy: 0.005)
    }

    func testEachWheelPushesTheWayItsPuckPoints() {
        // What the puck shows on the wheel is where the colours go on a
        // vectorscope, for every hue and every wheel.
        for hue in [0.0, 30, 60, 120, 180, 210, 240, 300] {
            let target = ColourWheels.wheelAngle(hue: hue)
            for (wheel, patch) in [(ColourWheels.Wheel.shadows, 0.2), (.midtones, 0.5), (.highlights, 0.8)] {
                let out = run([wheel.hueKey: .number(hue), wheel.amountKey: .number(40)], on: [grey(patch)])[0]
                XCTAssertLessThan(angleGap(angle(from: grey(patch), to: out), target), 1.5, "\(wheel) hue \(hue)")
            }
        }
    }

    func testBrightnessMovesItsOwnRange() {
        let lifted = run(["shadowsBrightness": .number(50)], on: [grey(0), grey(1)])
        assertClose(lifted[0], grey(0.075), 1e-3)
        assertClose(lifted[1], grey(1), 1e-3)
        let dimmed = run(["highlightsBrightness": .number(-40)], on: [grey(1), grey(0)])
        assertClose(dimmed[0], grey(0.9), 1e-3)
        assertClose(dimmed[1], grey(0), 1e-4)
        let mids = run(["midtonesBrightness": .number(50)], on: [grey(0.5), grey(0), grey(1)])
        assertClose(mids[0], grey(pow(0.5, pow(2, -0.25))), 1e-3)
        XCTAssertGreaterThan(mids[0].r, 0.55)
        assertClose(mids[1], grey(0), 1e-4)
        assertClose(mids[2], grey(1), 1e-3)
    }

    func testValuesOutsideTheUsualRangeStayFiniteAndInOrder() {
        // Super-whites and below-blacks, as extended-range sources or an
        // earlier effect can make: nothing turns into NaN, nothing clips,
        // and a ramp stays a ramp.
        let ramp = [-0.2, -0.05, 0, 0.3, 0.7, 1, 1.15, 1.4].map(grey)
        let params: [String: ParamValue] = [
            "shadowsHue": .number(200), "shadowsAmount": .number(80), "shadowsBrightness": .number(-30),
            "midtonesHue": .number(20), "midtonesAmount": .number(70), "midtonesBrightness": .number(40),
            "highlightsHue": .number(50), "highlightsAmount": .number(90), "highlightsBrightness": .number(60)
        ]
        let out = run(params, on: ramp)
        for (index, c) in out.enumerated() {
            XCTAssertTrue(c.r.isFinite && c.g.isFinite && c.b.isFinite, "patch \(index): \(c)")
        }
        for (a, b) in zip(out, out.dropFirst()) {
            XCTAssertLessThan(ColourWheels.luma(a), ColourWheels.luma(b))
        }
        XCTAssertGreaterThan(out.last!.r, 1.2, "super-whites aren't clipped")
        XCTAssertLessThan(out.first!.g, -0.1, "below-blacks aren't clipped")
        // The kernel and the CPU reference agree.
        let grade = ColourWheelGrade { params[$0]?.number ?? 0 }
        for (input, rendered) in zip(ramp, out) {
            assertClose(rendered, grade.apply(input), 0.004, "at \(input.r)")
        }
    }

    func testHuesWrapAndNegativeAmountsPointTheOtherWay() {
        let patch = [grey(0.5)]
        let a = run(["highlightsHue": .number(10), "highlightsAmount": .number(50)], on: patch)[0]
        let b = run(["highlightsHue": .number(370), "highlightsAmount": .number(50)], on: patch)[0]
        assertClose(a, b, 1e-4)
        let opposite = run(["highlightsHue": .number(10), "highlightsAmount": .number(-50)], on: patch)[0]
        XCTAssertLessThan(angleGap(angle(from: grey(0.5), to: opposite), ColourWheels.wheelAngle(hue: 190)), 1)
    }

    func testTheWheelsKernelDoesntInterfereWithTheOthers() {
        // Core Image once ran the first-used kernel's code for every kernel
        // compiled alongside it; each has its own library.
        let red = [ColourWheels.RGB(r: 0.8, g: 0.1, b: 0.1)]
        let env = EffectEnvironment(registry: .standard, folder: folder, pixelsPerUnit: 1)
        for type in ["colorWheels", "colorAdjust", "hsl", "colorWheels"] {
            let params: [String: ParamValue] = type == "colorWheels"
                ? ["highlightsBrightness": .number(-40)]
                : (type == "hsl" ? ["redSaturation": .number(-100)] : ["saturation": .number(-100)])
            let out = EffectRenderer.apply([Effect(type: type, params: params)], to: strip(red), env)
            var data = [Float](repeating: 0, count: 4)
            RenderEngine.context.render(out, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            if type == "colorWheels" {
                XCTAssertEqual(Double(data[0]), 0.72, accuracy: 0.003, type)
                XCTAssertEqual(Double(data[1]), 0.09, accuracy: 0.003, type)
            } else {
                XCTAssertEqual(data[0], data[1], accuracy: 0.01, type)
            }
        }
    }
}
