import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

final class EffectsTests: XCTestCase {
    let size = CGSize(width: 64, height: 64)
    let folder = ProjectFolder(root: URL(fileURLWithPath: NSTemporaryDirectory()))

    func run(_ effect: Effect, on image: CIImage, registry: EffectRegistry = .standard, unit: CGFloat = 1) -> Bitmap {
        let env = EffectEnvironment(registry: registry, folder: folder, pixelsPerUnit: unit)
        return Bitmap(EffectRenderer.apply([effect], to: image, env), size: size)
    }

    func grey(_ v: CGFloat) -> CIImage { solid(v, v, v, width: 64, height: 64) }

    func testColourDefaultsChangeNothing() {
        let out = run(Effect(type: "colorAdjust"), on: solid(0.2, 0.4, 0.6, width: 64, height: 64))
        assertColor(out[32, 32], [51, 102, 153], tolerance: 1)
    }

    func testExposureIsInStops() {
        // +1 stop doubles the light: 0.5 encoded is 0.218 linear, doubled
        // is 0.435, which encodes back to 0.685.
        let out = run(Effect(type: "colorAdjust", params: ["exposure": .number(1)]), on: grey(0.5))
        assertColor(out[32, 32], [175, 175, 175], tolerance: 2)
    }

    func testContrastPivotsOnMidGrey() {
        let dark = run(Effect(type: "colorAdjust", params: ["contrast": .number(100)]), on: grey(0.25))
        let light = run(Effect(type: "colorAdjust", params: ["contrast": .number(100)]), on: grey(0.75))
        let mid = run(Effect(type: "colorAdjust", params: ["contrast": .number(100)]), on: grey(0.5))
        XCTAssertLessThan(dark[32, 32][0], 60)
        XCTAssertGreaterThan(light[32, 32][0], 200)
        assertColor(mid[32, 32], [128, 128, 128], tolerance: 1)
    }

    func testSaturationAndTemperature() {
        let grey = run(Effect(type: "colorAdjust", params: ["saturation": .number(-100)]), on: solid(1, 0, 0, width: 64, height: 64))[32, 32]
        XCTAssertEqual(grey[0], grey[2], accuracy: 1)
        let warm = run(Effect(type: "colorAdjust", params: ["temperature": .number(100)]), on: self.grey(0.5))[32, 32]
        XCTAssertGreaterThan(warm[0], warm[2] + 20)
    }

    func testBlackLevelCrushesShadows() {
        let crushed = run(Effect(type: "colorAdjust", params: ["blackLevel": .number(-100)]), on: grey(0.1))[32, 32]
        XCTAssertLessThan(crushed[0], 8)
        // Mike's usual small values are subtle: 7 lifts a dark grey slightly.
        let lifted = run(Effect(type: "colorAdjust", params: ["blackLevel": .number(7)]), on: grey(0.2))[32, 32]
        XCTAssertEqual(lifted[0], 52, accuracy: 1)
    }

    func testHSLRedSaturationOnlyTouchesReds() {
        let effect = Effect(type: "hsl", params: ["redSaturation": .number(-100)])
        let red = run(effect, on: solid(0.8, 0.1, 0.1, width: 64, height: 64))[32, 32]
        XCTAssertEqual(red[0], red[1], accuracy: 2)
        let blue = run(effect, on: solid(0.1, 0.1, 0.8, width: 64, height: 64))[32, 32]
        assertColor(blue, [26, 26, 204], tolerance: 2)
    }

    func testHSLHueShiftMovesRedTowardsOrange() {
        let shifted = run(Effect(type: "hsl", params: ["redHue": .number(100)]), on: solid(1, 0, 0, width: 64, height: 64))[32, 32]
        XCTAssertGreaterThan(shifted[1], 100)
        XCTAssertGreaterThan(shifted[0], 200)
    }

    func testMikesSkinCalmingGradeIsGentle() {
        // Red saturation -8 on a skin tone moves it a little, not a lot.
        let skin = solid(0.85, 0.62, 0.5, width: 64, height: 64)
        let before = Bitmap(skin, size: size)[32, 32]
        let after = run(Effect(type: "hsl", params: ["redSaturation": .number(-8), "orangeSaturation": .number(-8)]), on: skin)[32, 32]
        XCTAssertLessThan(after[0] - after[2], before[0] - before[2])
        XCTAssertGreaterThan(after[0] - after[2], (before[0] - before[2]) * 3 / 4)
    }

    func testVignetteDarkensCornersNotCentre() {
        let out = run(Effect(type: "vignette", params: ["amount": .number(-50)]), on: grey(0.8))
        assertColor(out[32, 32], [204, 204, 204], tolerance: 1)
        XCTAssertLessThan(out[1, 1][0], 130)
    }

    func testSharpenIncreasesEdgeContrast() {
        let edge = split(CIColor(red: 0.3, green: 0.3, blue: 0.3), CIColor(red: 0.7, green: 0.7, blue: 0.7), width: 64, height: 64)
        let out = run(Effect(type: "sharpen", params: ["amount": .number(10)]), on: edge)
        XCTAssertLessThan(out[31, 32][0], 76)
        XCTAssertGreaterThan(out[32, 32][0], 179)
    }

    func testBlurSoftensEdgesButNotTheFrameBorder() {
        let edge = split(.black, .white, width: 64, height: 64)
        let out = run(Effect(type: "blur", params: ["radius": .number(4)]), on: edge, unit: 1)
        XCTAssertGreaterThan(out[31, 32][0], 40)
        XCTAssertLessThan(out[32, 32][0], 215)
        // Clamped at the frame edge, so the corner stays white, not faded.
        XCTAssertGreaterThan(out[63, 0][0], 250)
    }

    func testBlurRadiusFollowsPixelsPerUnit() {
        let edge = split(.black, .white, width: 64, height: 64)
        let narrow = run(Effect(type: "blur", params: ["radius": .number(2)]), on: edge, unit: 1)
        let wide = run(Effect(type: "blur", params: ["radius": .number(2)]), on: edge, unit: 4)
        XCTAssertGreaterThan(wide[26, 32][0], narrow[26, 32][0])
    }

    func testPixelateMakesBlocks() {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 0),
            "inputColor0": CIColor.black, "inputColor1": CIColor.white
        ])!.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        let out = run(Effect(type: "pixelate", params: ["scale": .number(16)]), on: gradient)
        XCTAssertEqual(out[1, 10], out[5, 10])
        XCTAssertNotEqual(out[1, 10], out[40, 10])
    }

    func testCoreImageBindingFromAPack() {
        var registry = EffectRegistry.standard
        registry.register(EffectDefinition(
            type: "invert", name: "Invert", category: "Utility", domain: .video, summary: "Negative.",
            params: [], coreImage: CoreImageBinding(filter: "CIColorInvert", inputs: [:])
        ))
        let out = run(Effect(type: "invert"), on: solid(1, 0, 0, width: 64, height: 64), registry: registry)
        assertColor(out[32, 32], [0, 255, 255], tolerance: 1)
    }

    func testUnknownAndDisabledEffectsAreSkipped() {
        let image = solid(1, 0, 0, width: 64, height: 64)
        assertColor(run(Effect(type: "mystery"), on: image)[32, 32], [255, 0, 0])
        assertColor(run(Effect(type: "colorAdjust", enabled: false, params: ["exposure": .number(2)]), on: image)[32, 32], [255, 0, 0])
    }

    func testLUTFromCubeFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-lut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 2-point inverting cube, red changing fastest.
        var text = "TITLE \"Invert\"\nLUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
        try text.write(to: dir.appendingPathComponent("invert.cube"), atomically: true, encoding: .utf8)
        let env = EffectEnvironment(registry: .standard, folder: ProjectFolder(root: dir), pixelsPerUnit: 1)
        let full = EffectRenderer.apply([Effect(type: "lut", params: ["path": .string("invert.cube")])], to: solid(1, 0, 0, width: 64, height: 64), env)
        assertColor(Bitmap(full, size: size)[32, 32], [0, 255, 255], tolerance: 2)
        let half = EffectRenderer.apply([Effect(type: "lut", params: ["path": .string("invert.cube"), "intensity": .number(0.5)])], to: solid(1, 0, 0, width: 64, height: 64), env)
        assertColor(Bitmap(half, size: size)[32, 32], [128, 128, 128], tolerance: 2)
        // A missing file leaves the picture alone.
        let missing = EffectRenderer.apply([Effect(type: "lut", params: ["path": .string("nope.cube")])], to: solid(1, 0, 0, width: 64, height: 64), env)
        assertColor(Bitmap(missing, size: size)[32, 32], [255, 0, 0])
    }

    func testCustomKernelsDontInterfere() {
        // Core Image once ran the first-used kernel's code for every kernel
        // compiled alongside it; each now has its own library.
        let image = solid(0.8, 0.1, 0.1, width: 64, height: 64)
        let order = ["colorAdjust", "hsl", "vignette", "colorAdjust", "hsl"]
        for type in order {
            let params: [String: ParamValue]
            switch type {
            case "colorAdjust": params = ["saturation": .number(-100)]
            case "hsl": params = ["redSaturation": .number(-100)]
            default: params = ["amount": .number(-100)]
            }
            let out = run(Effect(type: type, params: params), on: image)
            if type == "vignette" {
                XCTAssertEqual(out[32, 32][0], 204, accuracy: 1, type)
                XCTAssertLessThan(out[0, 0][0], 60, type)
            } else {
                XCTAssertEqual(out[32, 32][0], out[32, 32][1], accuracy: 2, type)
                XCTAssertGreaterThan(out[32, 32][0], 40, type)
            }
        }
    }

    func testCubeParsing() throws {
        let lut = try CubeLUT.parse("""
        # comment
        TITLE "Test"
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """)
        XCTAssertEqual(lut.title, "Test")
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.data.count, 32)
        XCTAssertEqual(Array(lut.data[4..<8]), [1, 0, 0, 1])
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n"))
        XCTAssertThrowsError(try CubeLUT.parse("0 0 0\n"))

        let oneD = try CubeLUT.parse("LUT_1D_SIZE 2\n1 1 1\n0 0 0\n")
        XCTAssertEqual(oneD.dimension, 33)
        XCTAssertEqual(Array(oneD.data[0..<4]), [1, 1, 1, 1])
        XCTAssertEqual(Array(oneD.data.suffix(4)), [0, 0, 0, 1])
    }
}
