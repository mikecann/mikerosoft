import CoreGraphics
import Darwin
import XCTest
@testable import TaskbarApp

final class FullscreenVisibilityTests: XCTestCase {
    private let screens = [
        ScreenInfo(
            id: 1,
            name: "Main",
            appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            quartzFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        ),
        ScreenInfo(
            id: 2,
            name: "Side",
            appKitFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
            quartzFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        )
    ]

    func testForegroundWindowCoveringScreenHidesOnlyThatScreensTaskbar() {
        let records = [record(
            pid: 200,
            bounds: CGRect(x: 2559, y: -1, width: 1922, height: 1082),
            isFullscreen: true
        )]

        let hiddenScreenIDs = fullscreenCoveredScreenIDs(
            records: records,
            screens: screens,
            frontmostPID: 200,
            currentPID: 999
        )

        XCTAssertEqual(hiddenScreenIDs, [2])
    }

    func testOrdinaryMaximizedWindowDoesNotHideTaskbar() {
        // macOS "Fill" can give a normal zoomed window the full screen-sized
        // frame. AXFullScreen remains false, which distinguishes it from true
        // fullscreen mode.
        let records = [record(pid: 200, bounds: screens[0].quartzFrame, isFullscreen: false)]

        let hiddenScreenIDs = fullscreenCoveredScreenIDs(
            records: records,
            screens: screens,
            frontmostPID: 200,
            currentPID: 999
        )

        XCTAssertTrue(hiddenScreenIDs.isEmpty)
    }

    func testBorderlessSteamGameStillHidesTaskbarWithoutNativeFullscreenState() {
        let records = [record(
            pid: 200,
            bounds: screens[0].quartzFrame,
            appPath: "/Users/mike/Library/Application Support/Steam/steamapps/common/Game/Game.app",
            isFullscreen: false
        )]

        let hiddenScreenIDs = fullscreenCoveredScreenIDs(
            records: records,
            screens: screens,
            frontmostPID: 200,
            currentPID: 999
        )

        XCTAssertEqual(hiddenScreenIDs, [1])
    }

    func testBackgroundFullscreenSizedWindowDoesNotHideTaskbar() {
        let records = [record(pid: 200, bounds: screens[0].quartzFrame)]

        let hiddenScreenIDs = fullscreenCoveredScreenIDs(
            records: records,
            screens: screens,
            frontmostPID: 201,
            currentPID: 999
        )

        XCTAssertTrue(hiddenScreenIDs.isEmpty)
    }

    private func record(
        pid: pid_t,
        bounds: CGRect,
        appPath: String = "/Applications/Game.app",
        isFullscreen: Bool? = nil
    ) -> WindowRecord {
        WindowRecord(
            owner: "Steam Game",
            title: "Game",
            pid: pid,
            windowID: 42,
            accessibilityWindowID: 42,
            layer: 0,
            isOnScreen: true,
            isMinimized: false,
            bounds: bounds,
            screenID: nil,
            bundleID: "com.example.game",
            appPath: appPath,
            accessibilityTitle: "Game",
            accessibilitySignature: "",
            isFullscreen: isFullscreen
        )
    }
}
