import CoreGraphics
import XCTest
@testable import TaskbarApp

final class WindowAvoidanceTests: XCTestCase {
    func record(
        owner: String = "Safari",
        title: String = "Article",
        pid: pid_t = 100,
        windowID: Int = 1,
        layer: Int = 0,
        isOnScreen: Bool = true,
        bounds: CGRect = CGRect(x: 80, y: 80, width: 1200, height: 1360),
        screenID: UInt32? = 1
    ) -> WindowRecord {
        WindowRecord(
            owner: owner,
            title: title,
            pid: pid,
            windowID: windowID,
            accessibilityWindowID: 0,
            layer: layer,
            isOnScreen: isOnScreen,
            isMinimized: false,
            bounds: bounds,
            screenID: screenID,
            bundleID: "",
            appPath: "",
            accessibilityTitle: "",
            accessibilitySignature: ""
        )
    }

    func screen() -> ScreenInfo {
        ScreenInfo(
            id: 1,
            name: "LG",
            appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            quartzFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
    }

    func values(
        isVisible: Bool = true,
        avoidOverlappingWindows: Bool = true,
        autoHide: Bool = false,
        taskbarHeight: Double = 54
    ) -> TaskbarSettingValues {
        var values = TaskbarSettingValues.defaults
        values.isVisible = isVisible
        values.avoidOverlappingWindows = avoidOverlappingWindows
        values.autoHide = autoHide
        values.taskbarHeight = taskbarHeight
        return values
    }

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

    func testFullscreenWindowIsNotResizedToMakeRoomForTaskbar() {
        let requests = windowAdjustmentRequests(
            records: [record(pid: 100, windowID: 1, bounds: screen().quartzFrame)],
            screens: [screen()],
            valuesByScreen: [1: values()],
            currentPID: 999
        )

        XCTAssertTrue(requests.isEmpty)
    }

    func testWindowAdjustmentRequestsIncludeOnlyWindowsThatNeedClamping() {
        let records = [
            record(pid: 100, windowID: 1),
            record(pid: 101, windowID: 2, bounds: CGRect(x: 80, y: 80, width: 1200, height: 500)),
            record(pid: 102, windowID: 3, layer: 1),
            record(pid: 103, windowID: 4, isOnScreen: false),
            record(pid: 999, windowID: 5)
        ]

        let requests = windowAdjustmentRequests(
            records: records,
            screens: [screen()],
            valuesByScreen: [1: values()],
            currentPID: 999
        )

        XCTAssertEqual(
            requests,
            [
                WindowAdjustmentRequest(
                    windowID: 1,
                    pid: 100,
                    originalFrame: CGRect(x: 80, y: 80, width: 1200, height: 1360),
                    clampedFrame: CGRect(x: 80, y: 80, width: 1200, height: 1306)
                )
            ]
        )
    }

    func testWindowAdjustmentRequestsSkipAutoHiddenOrDisabledTaskbars() {
        let records = [record(pid: 100, windowID: 1)]

        XCTAssertTrue(
            windowAdjustmentRequests(
                records: records,
                screens: [screen()],
                valuesByScreen: [1: values(autoHide: true)],
                currentPID: 999
            ).isEmpty
        )
        XCTAssertTrue(
            windowAdjustmentRequests(
                records: records,
                screens: [screen()],
                valuesByScreen: [1: values(avoidOverlappingWindows: false)],
                currentPID: 999
            ).isEmpty
        )
        XCTAssertTrue(
            windowAdjustmentRequests(
                records: records,
                screens: [screen()],
                valuesByScreen: [1: values(isVisible: false)],
                currentPID: 999
            ).isEmpty
        )
    }

    func testWindowAdjustmentRequestsDeduplicateWindowIDs() {
        let records = [
            record(pid: 100, windowID: 1),
            record(pid: 100, windowID: 1)
        ]

        let requests = windowAdjustmentRequests(
            records: records,
            screens: [screen()],
            valuesByScreen: [1: values()],
            currentPID: 999
        )

        XCTAssertEqual(requests.map(\.windowID), [1])
    }
}
