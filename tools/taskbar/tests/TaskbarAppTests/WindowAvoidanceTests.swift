import CoreGraphics
import XCTest
@testable import TaskbarApp

final class WindowAvoidanceTests: XCTestCase {
    func testAccessibilityTrustPromptsOnlyOnceWhilePermissionIsMissing() {
        var state = AccessibilityTrustState()
        var promptCount = 0

        for _ in 0..<3 {
            let trusted = state.isTrusted(
                isCurrentlyTrusted: { false },
                promptForTrust: {
                    promptCount += 1
                    return false
                }
            )

            XCTAssertFalse(trusted)
        }

        XCTAssertEqual(promptCount, 1)
    }

    func testAccessibilityTrustDoesNotPromptWhenAlreadyTrusted() {
        var state = AccessibilityTrustState()
        var promptCount = 0

        let trusted = state.isTrusted(
            isCurrentlyTrusted: { true },
            promptForTrust: {
                promptCount += 1
                return false
            }
        )

        XCTAssertTrue(trusted)
        XCTAssertEqual(promptCount, 0)
    }

    func testWindowFrameIsReducedWhenItOverlapsTheTaskbarReserve() {
        let screen = ScreenInfo(
            id: 1,
            name: "LG",
            appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            quartzFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        let frame = CGRect(x: 80, y: 80, width: 1200, height: 1360)

        let clamped = clampedWindowFrame(frame, screen: screen, reservedBottomHeight: 54)

        XCTAssertEqual(clamped, CGRect(x: 80, y: 80, width: 1200, height: 1306))
    }

    func testWindowFrameIsUnchangedWhenItAlreadySitsAboveTheTaskbarReserve() {
        let screen = ScreenInfo(
            id: 1,
            name: "LG",
            appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            quartzFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        let frame = CGRect(x: 80, y: 80, width: 1200, height: 500)

        XCTAssertNil(clampedWindowFrame(frame, screen: screen, reservedBottomHeight: 54))
    }
}
