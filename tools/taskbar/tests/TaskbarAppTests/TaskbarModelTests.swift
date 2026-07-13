import CoreGraphics
import XCTest
@testable import TaskbarApp

final class TaskbarModelTests: XCTestCase {
    func record(
        owner: String,
        title: String,
        pid: pid_t = 100,
        windowID: Int = 1,
        layer: Int = 0,
        isOnScreen: Bool = true,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600),
        screenID: UInt32? = 1,
        bundleID: String = "",
        appPath: String = "",
        accessibilitySignature: String = ""
    ) -> WindowRecord {
        WindowRecord(
            owner: owner,
            title: title,
            pid: pid,
            windowID: windowID,
            layer: layer,
            isOnScreen: isOnScreen,
            bounds: bounds,
            screenID: screenID,
            bundleID: bundleID,
            appPath: appPath,
            accessibilitySignature: accessibilitySignature
        )
    }

    func testVisibleWindowsRejectsDesktopPanelsAndTinyHelpers() {
        let records = [
            record(owner: "Safari", title: "Article", pid: 10, windowID: 1),
            record(owner: "Dock", title: "Dock", pid: 11, windowID: 2),
            record(owner: "Messages", title: "Badge", pid: 12, windowID: 3, bounds: CGRect(x: 0, y: 0, width: 20, height: 20)),
            record(owner: "Finder", title: "Desktop", pid: 13, windowID: 4, layer: -2147483623),
            record(owner: "Notes", title: "Hidden", pid: 14, windowID: 5, isOnScreen: false)
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.owner), ["Safari"])
    }

    func testVisibleWindowsRejectsTaskbarPanelsButKeepsSettingsWindow() {
        let records = [
            record(owner: "Taskbar", title: "mikerosoft taskbar", pid: 42, windowID: 1),
            record(owner: "Taskbar", title: "Taskbar Settings", pid: 42, windowID: 3),
            record(owner: "Terminal", title: "zsh", pid: 99, windowID: 2)
        ]

        let visible = visibleWindows(records, currentPID: 42)

        XCTAssertEqual(visible.map(\.title), ["Taskbar Settings", "zsh"])
    }

    func testVisibleWindowsRejectsDuplicateAccessibilitySurfaces() {
        let records = [
            record(
                owner: "Notion",
                title: "Convex + AI Quick Tips",
                pid: 10,
                windowID: 1,
                bounds: CGRect(x: 0, y: 31, width: 2560, height: 1379),
                bundleID: "notion.id",
                accessibilitySignature: "children:a,b,c,d"
            ),
            record(
                owner: "Notion",
                title: "Convex + AI Quick Tips",
                pid: 10,
                windowID: 2,
                bounds: CGRect(x: 1218, y: 298, width: 2560, height: 690),
                bundleID: "notion.id",
                accessibilitySignature: "children:a,b,c,d"
            ),
            record(
                owner: "Finder",
                title: "Downloads",
                pid: 20,
                windowID: 3
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [1, 3])
    }

    func testVisibleWindowsKeepsRealSameTitleWindowsWhenAccessibilitySurfacesDiffer() {
        let records = [
            record(
                owner: "Notion",
                title: "Untitled",
                pid: 10,
                windowID: 1,
                bundleID: "notion.id",
                accessibilitySignature: "children:a,b,c,d"
            ),
            record(
                owner: "Notion",
                title: "Untitled",
                pid: 10,
                windowID: 2,
                bundleID: "notion.id",
                accessibilitySignature: "children:e,f,g,h"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [1, 2])
    }

    func testVisibleWindowsRejectsOverlappingSameTitleFallbackSurfaces() {
        let records = [
            record(
                owner: "Notion",
                title: "Convex + AI Quick Tips",
                pid: 10,
                windowID: 1,
                bounds: CGRect(x: 0, y: 31, width: 2560, height: 1379),
                bundleID: "notion.id"
            ),
            record(
                owner: "Notion",
                title: "Convex + AI Quick Tips",
                pid: 10,
                windowID: 2,
                bounds: CGRect(x: 1218, y: 298, width: 2560, height: 690),
                bundleID: "notion.id"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [1])
    }

    func testVisibleWindowsKeepsSameTitleFallbackWindowsWhenTheyDoNotOverlap() {
        let records = [
            record(
                owner: "Notion",
                title: "Untitled",
                pid: 10,
                windowID: 1,
                bounds: CGRect(x: 0, y: 31, width: 900, height: 700),
                bundleID: "notion.id"
            ),
            record(
                owner: "Notion",
                title: "Untitled",
                pid: 10,
                windowID: 2,
                bounds: CGRect(x: 1000, y: 31, width: 900, height: 700),
                bundleID: "notion.id"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [1, 2])
    }

    func testBuildItemsAlwaysShowsIndividualWindowsEvenIfOldSettingRequestsGrouping() {
        let windows = [
            record(owner: "Safari", title: "Article", pid: 10, windowID: 1),
            record(owner: "Safari", title: "Docs", pid: 10, windowID: 2),
            record(owner: "Terminal", title: "zsh", pid: 20, windowID: 3)
        ]

        let items = buildTaskbarItems(windows: windows, frontmostPID: nil, groupByApp: true)

        XCTAssertEqual(items.map(\.title), ["Article", "Docs", "zsh"])
        XCTAssertEqual(items.map(\.windowIDs), [[1], [2], [3]])
    }

    func testBuildItemsCanShowIndividualWindows() {
        let windows = [
            record(owner: "Safari", title: "Article", pid: 10, windowID: 1),
            record(owner: "Safari", title: "Docs", pid: 10, windowID: 2)
        ]

        let items = buildTaskbarItems(windows: windows, frontmostPID: nil, groupByApp: false)

        XCTAssertEqual(items.map(\.title), ["Article", "Docs"])
        XCTAssertEqual(items.map(\.windowIDs), [[1], [2]])
    }

    func testBuildItemsMarksFrontmostAppWithoutMovingIt() {
        let windows = [
            record(owner: "Safari", title: "Article", pid: 10, windowID: 1),
            record(owner: "Terminal", title: "zsh", pid: 20, windowID: 2),
            record(owner: "Notes", title: "Planning", pid: 30, windowID: 3)
        ]

        let items = buildTaskbarItems(windows: windows, frontmostPID: 20, groupByApp: true)

        XCTAssertEqual(items.map(\.owner), ["Notes", "Safari", "Terminal"])
        XCTAssertTrue(items[2].isFrontmost)
    }

    func testPinnedAppsStayFirstAndKeepTheirOrder() {
        let windows = [
            record(owner: "Safari", title: "Article", pid: 10, windowID: 1, bundleID: "com.apple.Safari"),
            record(owner: "Terminal", title: "zsh", pid: 20, windowID: 2, bundleID: "com.apple.Terminal"),
            record(owner: "Notes", title: "Planning", pid: 30, windowID: 3, bundleID: "com.apple.Notes")
        ]
        let pinned = [
            PinnedApp(displayName: "Terminal", bundleID: "com.apple.Terminal", appPath: "/System/Applications/Utilities/Terminal.app"),
            PinnedApp(displayName: "Safari", bundleID: "com.apple.Safari", appPath: "/Applications/Safari.app")
        ]

        let items = buildTaskbarItems(windows: windows, frontmostPID: nil, groupByApp: true, pinnedApps: pinned)

        XCTAssertEqual(items.map(\.owner), ["Terminal", "Safari", "Notes"])
        XCTAssertEqual(items.map(\.isPinned), [true, true, false])
    }

    func testClosedPinnedAppsRemainVisible() {
        let windows = [
            record(owner: "Notes", title: "Planning", pid: 30, windowID: 3, bundleID: "com.apple.Notes")
        ]
        let pinned = [
            PinnedApp(displayName: "Safari", bundleID: "com.apple.Safari", appPath: "/Applications/Safari.app")
        ]

        let items = buildTaskbarItems(windows: windows, frontmostPID: nil, groupByApp: true, pinnedApps: pinned)

        XCTAssertEqual(items.map(\.owner), ["Safari", "Notes"])
        XCTAssertEqual(items[0].pid, nil)
        XCTAssertEqual(items[0].windowCount, 0)
        XCTAssertTrue(items[0].isPinned)
    }
}
