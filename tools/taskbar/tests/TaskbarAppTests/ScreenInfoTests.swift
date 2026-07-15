import CoreGraphics
import XCTest
@testable import TaskbarApp

final class ScreenInfoTests: XCTestCase {
    func testElevatedSecondaryUsesDisplayBoundsForWindowAttribution() {
        let screens = screenInfos(
            from: [
                ScreenSnapshot(
                    id: 1,
                    name: "Primary",
                    appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                ),
                ScreenSnapshot(
                    id: 2,
                    name: "Elevated",
                    appKitFrame: CGRect(x: 0, y: 1080, width: 1920, height: 1200),
                    displayBounds: CGRect(x: 0, y: -1200, width: 1920, height: 1200)
                ),
                ScreenSnapshot(
                    id: 3,
                    name: "Left",
                    appKitFrame: CGRect(x: -1280, y: 0, width: 1280, height: 1024),
                    displayBounds: CGRect(x: -1280, y: 56, width: 1280, height: 1024)
                )
            ]
        )

        XCTAssertEqual(
            screenIDForWindow(
                bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                screens: screens
            ),
            1
        )
        XCTAssertEqual(
            screenIDForWindow(
                bounds: CGRect(x: 100, y: -1100, width: 800, height: 600),
                screens: screens
            ),
            2
        )
    }

    func testFallbackConversionResolvesSideBySideAndBelowPrimaryScreens() {
        let screens = screenInfos(
            from: [
                ScreenSnapshot(
                    id: 1,
                    name: "Primary",
                    appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    displayBounds: nil
                ),
                ScreenSnapshot(
                    id: 2,
                    name: "Right",
                    appKitFrame: CGRect(x: 1920, y: 0, width: 1600, height: 1080),
                    displayBounds: nil
                ),
                ScreenSnapshot(
                    id: 3,
                    name: "Below",
                    appKitFrame: CGRect(x: 0, y: -900, width: 1440, height: 900),
                    displayBounds: nil
                )
            ]
        )

        XCTAssertEqual(
            screenIDForWindow(
                bounds: CGRect(x: 2000, y: 100, width: 800, height: 600),
                screens: screens
            ),
            2
        )
        XCTAssertEqual(
            screenIDForWindow(
                bounds: CGRect(x: 100, y: 1180, width: 800, height: 600),
                screens: screens
            ),
            3
        )
    }

    func testElevatedSecondaryClampsWindowsAgainstItsTrueQuartzRegion() throws {
        let elevated = try XCTUnwrap(
            screenInfos(
                from: [
                    ScreenSnapshot(
                        id: 1,
                        name: "Primary",
                        appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                    ),
                    ScreenSnapshot(
                        id: 2,
                        name: "Elevated",
                        appKitFrame: CGRect(x: 0, y: 1080, width: 1920, height: 1200),
                        displayBounds: CGRect(x: 0, y: -1200, width: 1920, height: 1200)
                    )
                ]
            ).last
        )

        XCTAssertEqual(
            clampedWindowFrame(
                CGRect(x: 100, y: -1180, width: 800, height: 1180),
                screen: elevated,
                reservedBottomHeight: 54
            ),
            CGRect(x: 100, y: -1180, width: 800, height: 1126)
        )
    }
}
