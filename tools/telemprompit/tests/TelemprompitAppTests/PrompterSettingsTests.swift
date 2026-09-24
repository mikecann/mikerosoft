import XCTest
@testable import TelemprompitApp

final class PrompterSettingsTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        var settings = PrompterSettings.defaults
        settings.fontSize = 88
        settings.mirrorHorizontally = true
        settings.textColor = "#FFEE00"
        settings.alignment = .center
        let decoded = try JSONDecoder().decode(
            PrompterSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
    }

    func testMissingKeysFallBackToDefaultsSoOlderSettingsStillLoad() throws {
        let decoded = try JSONDecoder().decode(
            PrompterSettings.self,
            from: Data(#"{"fontSize": 70}"#.utf8)
        )
        var expected = PrompterSettings.defaults
        expected.fontSize = 70
        XCTAssertEqual(decoded, expected)
    }

    func testValuesAreClampedToUsableRanges() {
        var settings = PrompterSettings.defaults
        settings.fontSize = 2
        settings.readingLine = 3
        settings.scrollSpeed = -5
        settings.upcomingOpacity = 0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.fontSize, PrompterSettings.fontSizeRange.lowerBound)
        XCTAssertEqual(clamped.readingLine, PrompterSettings.readingLineRange.upperBound)
        XCTAssertEqual(clamped.scrollSpeed, PrompterSettings.scrollSpeedRange.lowerBound)
        XCTAssertEqual(clamped.upcomingOpacity, PrompterSettings.opacityRange.lowerBound)
    }

    func testStoreSavesAndReloads() {
        let defaults = UserDefaults(suiteName: "telemprompit-tests-\(UUID().uuidString)")!
        var settings = PrompterSettings.defaults
        settings.scrollSpeed = 123
        PrompterSettings.save(settings, to: defaults)
        XCTAssertEqual(PrompterSettings.load(from: defaults), settings)
    }

    func testHexColours() {
        XCTAssertEqual(HexColor.components("#FF8000"), [1, 128.0 / 255, 0])
        XCTAssertEqual(HexColor.components("00ff00"), [0, 1, 0])
        XCTAssertNil(HexColor.components("#12"))
        XCTAssertEqual(HexColor.string(red: 1, green: 0.5, blue: 0), "#FF8000")
    }
}
