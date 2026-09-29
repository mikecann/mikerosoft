import XCTest
@testable import TandemCore

/// The colour wheels' geometry: hues on a wheel laid out like a BT.709
/// vectorscope, and the colour each one pushes towards.
final class ColourWheelsTests: XCTestCase {
    func testPrimariesSitWhereAVectorscopePutsThem() {
        // BT.709 targets, degrees anticlockwise from Cb to the right.
        let expected: [(hue: Double, angle: Double)] = [
            (0, 102.9),     // red
            (60, 174.8),    // yellow
            (120, 229.7),   // green
            (180, 282.9),   // cyan
            (240, 354.8),   // blue
            (300, 49.7)     // magenta
        ]
        for (hue, angle) in expected {
            XCTAssertEqual(ColourWheels.wheelAngle(hue: hue), angle, accuracy: 0.1, "hue \(hue)")
        }
        // Complementary colours sit opposite each other.
        for hue in stride(from: 0.0, to: 180, by: 15) {
            let across = ColourWheels.normalised(ColourWheels.wheelAngle(hue: hue + 180) - ColourWheels.wheelAngle(hue: hue))
            XCTAssertEqual(across, 180, accuracy: 1e-9, "hue \(hue)")
        }
    }

    func testHueAndWheelAngleRoundTrip() {
        for hue in stride(from: 0.0, to: 360, by: 7.5) {
            let angle = ColourWheels.wheelAngle(hue: hue)
            XCTAssertEqual(ColourWheels.hue(wheelAngle: angle), hue, accuracy: 1e-6, "hue \(hue)")
        }
        // Going round the hues goes round the wheel one way, once.
        var turned = 0.0
        var last = ColourWheels.wheelAngle(hue: 0)
        for hue in stride(from: 1.0, through: 360, by: 1) {
            let angle = ColourWheels.wheelAngle(hue: hue)
            var step = angle - last
            if step < -180 { step += 360 }
            XCTAssertGreaterThan(step, 0, "hue \(hue)")
            turned += step
            last = angle
        }
        XCTAssertEqual(turned, 360, accuracy: 1e-6)
    }

    func testDirectionsHaveNoLumaAndOneUnitOfChroma() {
        for hue in stride(from: 0.0, to: 360, by: 15) {
            let d = ColourWheels.direction(hue: hue)
            XCTAssertEqual(ColourWheels.luma(d), 0, accuracy: 1e-12, "hue \(hue)")
            let c = ColourWheels.chroma(d)
            XCTAssertEqual((c.cb * c.cb + c.cr * c.cr).squareRoot(), 1, accuracy: 1e-12, "hue \(hue)")
            // The same hue as the colour it's named after.
            XCTAssertEqual(ColourWheels.hue(of: d) ?? -1, hue, accuracy: 1e-6, "hue \(hue)")
        }
        // Red raises red; blue raises blue and lowers the rest a little.
        let red = ColourWheels.direction(hue: 0)
        XCTAssertGreaterThan(red.r, 1)
        XCTAssertLessThan(red.g, 0)
        let blue = ColourWheels.direction(hue: 240)
        XCTAssertGreaterThan(blue.b, 1.8)
        XCTAssertEqual(blue.r, blue.g, accuracy: 1e-12)
    }

    func testHuesWrap() {
        XCTAssertEqual(ColourWheels.wheelAngle(hue: 370), ColourWheels.wheelAngle(hue: 10), accuracy: 1e-9)
        XCTAssertEqual(ColourWheels.wheelAngle(hue: -30), ColourWheels.wheelAngle(hue: 330), accuracy: 1e-9)
        XCTAssertEqual(ColourWheels.normalised(-0.5), 359.5, accuracy: 1e-12)
        XCTAssertEqual(ColourWheels.normalised(.nan), 0)
        XCTAssertNil(ColourWheels.hue(of: ColourWheels.RGB(r: 0.4, g: 0.4, b: 0.4)))
    }

    func testPuckPositionsRoundTrip() {
        for hue in stride(from: 0.0, to: 360, by: 20) {
            for amount in [5.0, 37, 100] {
                let puck = ColourWheels.puck(hue: hue, amount: amount)
                let back = ColourWheels.hueAndAmount(x: puck.x, y: puck.y)
                XCTAssertEqual(back.hue, hue, accuracy: 1e-6)
                XCTAssertEqual(back.amount, amount, accuracy: 1e-9)
            }
        }
        // Red is up and to the left, blue just below the right.
        let red = ColourWheels.puck(hue: 0, amount: 100)
        XCTAssertLessThan(red.x, 0)
        XCTAssertGreaterThan(red.y, 0.9)
        let blue = ColourWheels.puck(hue: 240, amount: 100)
        XCTAssertGreaterThan(blue.x, 0.9)
        XCTAssertLessThan(blue.y, 0)
    }

    func testPuckStaysInsideTheWheelAndKeepsItsHueInTheMiddle() {
        let outside = ColourWheels.hueAndAmount(x: 3, y: 4)
        XCTAssertEqual(outside.amount, 100)
        let centre = ColourWheels.hueAndAmount(x: 0, y: 0, keeping: 212)
        XCTAssertEqual(centre.hue, 212)
        XCTAssertEqual(centre.amount, 0)
    }

    func testRegistryDefinesTheWheels() throws {
        let definition = try XCTUnwrap(EffectRegistry.standard.definition("colorWheels"))
        XCTAssertEqual(definition.category, "Colour")
        XCTAssertEqual(definition.domain, .video)
        XCTAssertEqual(definition.params.map(\.key), ColourWheels.keys)
        XCTAssertEqual(ColourWheels.keys, [
            "shadowsHue", "shadowsAmount", "shadowsBrightness",
            "midtonesHue", "midtonesAmount", "midtonesBrightness",
            "highlightsHue", "highlightsAmount", "highlightsBrightness"
        ])
        // Every default is neutral.
        XCTAssertTrue(definition.params.allSatisfy { $0.defaultValue == .number(0) })
    }
}
