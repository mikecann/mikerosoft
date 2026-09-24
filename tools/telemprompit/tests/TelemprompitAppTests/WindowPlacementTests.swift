import XCTest
@testable import TelemprompitApp

final class WindowPlacementTests: XCTestCase {
    private let prompter = WindowPlacement.Screen(name: "Elgato Prompter", visibleFrame: CGRect(x: 3000, y: 0, width: 1024, height: 600))
    private let laptop = WindowPlacement.Screen(name: "Color LCD", visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944))

    func testPrefersThePrompterDisplay() {
        XCTAssertEqual(WindowPlacement.targetScreen(in: [laptop, prompter])?.name, "Elgato Prompter")
    }

    func testFallsBackToTheFirstScreenWhenThePrompterIsNotConnected() {
        XCTAssertEqual(WindowPlacement.targetScreen(in: [laptop])?.name, "Color LCD")
        XCTAssertNil(WindowPlacement.targetScreen(in: []))
    }

    func testFillsThePrompterByDefault() {
        XCTAssertEqual(
            WindowPlacement.frame(on: prompter, saved: [:]),
            CGRect(x: 3000, y: 32, width: 1024, height: 568)
        )
    }

    func testUsesACentredWindowOnOtherScreens() {
        let frame = WindowPlacement.frame(on: laptop, saved: [:])
        XCTAssertEqual(frame.size, WindowPlacement.fallbackSize)
        XCTAssertEqual(frame.midX, laptop.visibleFrame.midX)
        XCTAssertEqual(frame.midY, laptop.visibleFrame.midY)
    }

    func testRestoresTheFrameLastUsedOnThatScreen() {
        let saved = ["Elgato Prompter": CGRect(x: 3100, y: 100, width: 600, height: 400)]
        XCTAssertEqual(WindowPlacement.frame(on: prompter, saved: saved), saved["Elgato Prompter"])
    }

    func testIgnoresASavedFrameThatNoLongerFitsOnTheScreen() {
        let saved = ["Color LCD": CGRect(x: 5000, y: 5000, width: 600, height: 400)]
        XCTAssertEqual(WindowPlacement.frame(on: laptop, saved: saved).size, WindowPlacement.fallbackSize)
    }
}

final class PrompterClickZonesTests: XCTestCase {
    private let size = CGSize(width: 800, height: 600)

    func testClicksInTheScriptAdvance() {
        XCTAssertTrue(PrompterClickZones.advances(at: CGPoint(x: 400, y: 300), in: size))
        XCTAssertTrue(PrompterClickZones.advances(at: CGPoint(x: 10, y: 10), in: size))
    }

    func testTheHandleStripAndResizeGripDoNotAdvance() {
        XCTAssertFalse(PrompterClickZones.advances(at: CGPoint(x: 400, y: 590), in: size))
        XCTAssertFalse(PrompterClickZones.advances(at: CGPoint(x: 790, y: 10), in: size))
    }
}
