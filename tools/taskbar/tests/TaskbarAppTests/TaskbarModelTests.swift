import CoreGraphics
import XCTest
@testable import TaskbarApp

final class TaskbarModelTests: XCTestCase {
    func record(
        owner: String,
        title: String,
        pid: pid_t = 100,
        windowID: Int = 1,
        accessibilityWindowID: Int = 0,
        layer: Int = 0,
        isOnScreen: Bool = true,
        isMinimized: Bool = false,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600),
        screenID: UInt32? = 1,
        bundleID: String = "",
        appPath: String = "",
        accessibilityTitle: String = "",
        accessibilitySignature: String = ""
    ) -> WindowRecord {
        WindowRecord(
            owner: owner,
            title: title,
            pid: pid,
            windowID: windowID,
            accessibilityWindowID: accessibilityWindowID,
            layer: layer,
            isOnScreen: isOnScreen,
            isMinimized: isMinimized,
            bounds: bounds,
            screenID: screenID,
            bundleID: bundleID,
            appPath: appPath,
            accessibilityTitle: accessibilityTitle,
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

    func testVisibleWindowsCanIncludeMinimizedWindowsWhenEnabled() {
        let records = [
            record(owner: "Safari", title: "Visible", pid: 10, windowID: 1),
            record(owner: "Notes", title: "Minimized", pid: 14, windowID: 5, isOnScreen: false, isMinimized: true),
            record(owner: "Finder", title: "Hidden", pid: 15, windowID: 6, isOnScreen: false)
        ]

        let hiddenByDefault = visibleWindows(records, currentPID: 999)
        let visibleWithMinimized = visibleWindows(records, currentPID: 999, includeMinimized: true)

        XCTAssertEqual(hiddenByDefault.map(\.title), ["Visible"])
        XCTAssertEqual(visibleWithMinimized.map(\.title), ["Visible", "Minimized"])
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

    func testVisibleWindowsRejectsDuplicateAccessibilitySurfacesWhenTitlesDiffer() {
        let records = [
            record(
                owner: "Notion",
                title: "Project Plan",
                pid: 10,
                windowID: 1,
                bounds: CGRect(x: 0, y: 31, width: 2560, height: 1379),
                bundleID: "notion.id",
                accessibilitySignature: "children:a,b,c,d"
            ),
            record(
                owner: "Notion",
                title: "Notion",
                pid: 10,
                windowID: 2,
                bounds: CGRect(x: 1218, y: 298, width: 2560, height: 690),
                bundleID: "notion.id",
                accessibilitySignature: "children:a,b,c,d"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [1])
        XCTAssertEqual(visible.map(\.title), ["Project Plan"])
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

    func testVisibleWindowsKeepsChromeProfileWindowsWithSameStructureAndDifferentAccessibilityTitles() {
        let bounds = CGRect(x: 0, y: 30, width: 2560, height: 1378)
        let records = [
            record(
                owner: "Google Chrome",
                title: "New Tab",
                pid: 739,
                windowID: 578,
                bounds: bounds,
                bundleID: "com.google.Chrome",
                accessibilityTitle: "New Tab - Google Chrome - Michael",
                accessibilitySignature: "same-chrome-child-structure"
            ),
            record(
                owner: "Google Chrome",
                title: "New tab",
                pid: 739,
                windowID: 16416,
                bounds: bounds,
                bundleID: "com.google.Chrome",
                accessibilityTitle: "New tab - Google Chrome - Michael (convex.dev)",
                accessibilitySignature: "same-chrome-child-structure"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [578, 16416])
    }

    func testVisibleWindowsKeepsDifferentProvenAccessibilityWindowIDs() {
        let bounds = CGRect(x: 0, y: 30, width: 2560, height: 1378)
        let records = [
            record(
                owner: "Google Chrome",
                title: "Issue 25 - GitHub",
                pid: 739,
                windowID: 578,
                accessibilityWindowID: 578,
                bounds: bounds,
                bundleID: "com.google.Chrome"
            ),
            record(
                owner: "Google Chrome",
                title: "Issue 25 - GitHub",
                pid: 739,
                windowID: 16416,
                accessibilityWindowID: 16416,
                bounds: bounds,
                bundleID: "com.google.Chrome"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [578, 16416])
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

    func testVisibleWindowsRejectsOverlappingFallbackSurfacesWhenOneTitleIsJustOwner() {
        let records = [
            record(
                owner: "Notion",
                title: "Project Plan",
                pid: 10,
                windowID: 1,
                bounds: CGRect(x: 0, y: 31, width: 2560, height: 1379),
                bundleID: "notion.id"
            ),
            record(
                owner: "Notion",
                title: "Notion",
                pid: 10,
                windowID: 2,
                bounds: CGRect(x: 1218, y: 298, width: 2560, height: 690),
                bundleID: "notion.id"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [1])
        XCTAssertEqual(visible.map(\.title), ["Project Plan"])
    }

    func testVisibleWindowsRejectsTinyUntitledInternalSiblingSurface() {
        let records = [
            record(
                owner: "Wondershare Filmora Mac",
                title: "",
                pid: 89910,
                windowID: 8017,
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1408),
                bundleID: "com.wondershare.filmoramacos",
                appPath: "/Applications/Wondershare Filmora Mac.app",
                accessibilitySignature: "main-window-children"
            ),
            record(
                owner: "Wondershare Filmora Mac",
                title: "",
                pid: 89910,
                windowID: 8954,
                bounds: CGRect(x: 1024, y: 627, width: 113, height: 64),
                bundleID: "com.wondershare.filmoramacos",
                appPath: "/Applications/Wondershare Filmora Mac.app"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [8017])
    }

    func testVisibleWindowsKeepsUntitledInternalSizedSurfaceFromDifferentApp() {
        let records = [
            record(
                owner: "Wondershare Filmora Mac",
                title: "",
                pid: 89910,
                windowID: 8017,
                accessibilityWindowID: 8017,
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1408),
                bundleID: "com.wondershare.filmoramacos"
            ),
            record(
                owner: "Preview",
                title: "",
                pid: 455,
                windowID: 9000,
                bounds: CGRect(x: 1024, y: 627, width: 113, height: 64),
                bundleID: "com.apple.Preview"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [8017, 9000])
    }

    func testVisibleWindowsKeepsTinyTitledSiblingWindow() {
        let records = [
            record(
                owner: "Wondershare Filmora Mac",
                title: "",
                pid: 89910,
                windowID: 8017,
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1408),
                bundleID: "com.wondershare.filmoramacos",
                appPath: "/Applications/Wondershare Filmora Mac.app"
            ),
            record(
                owner: "Wondershare Filmora Mac",
                title: "Importing files",
                pid: 89910,
                windowID: 8500,
                bounds: CGRect(x: 1030, y: 542, width: 480, height: 245),
                bundleID: "com.wondershare.filmoramacos",
                appPath: "/Applications/Wondershare Filmora Mac.app"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [8017, 8500])
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

    func testVisibleWindowsRejectsRecordsWithTheSamePositiveWindowID() {
        let records = [
            record(
                owner: "Google Chrome",
                title: "Inbox",
                pid: 739,
                windowID: 16416,
                bounds: CGRect(x: 0, y: 30, width: 1200, height: 900),
                bundleID: "com.google.Chrome",
                accessibilityTitle: "Inbox - Google Chrome",
                accessibilitySignature: "profile-a-window"
            ),
            record(
                owner: "Google Chrome",
                title: "New tab",
                pid: 739,
                windowID: 16416,
                bounds: CGRect(x: 1300, y: 30, width: 1200, height: 900),
                bundleID: "com.google.Chrome",
                accessibilityTitle: "New tab - Google Chrome",
                accessibilitySignature: "profile-b-window"
            )
        ]

        let visible = visibleWindows(records, currentPID: 999)

        XCTAssertEqual(visible.map(\.windowID), [16416])
    }

    func testBuildItemsCanShowIndividualWindows() {
        let windows = [
            record(owner: "Safari", title: "Article", pid: 10, windowID: 1),
            record(owner: "Safari", title: "Docs", pid: 10, windowID: 2)
        ]

        let items = buildTaskbarItems(windows: windows, frontmostPID: nil)

        XCTAssertEqual(items.map(\.title), ["Article", "Docs"])
        XCTAssertEqual(items.map(\.windowIDs), [[1], [2]])
    }

    func testBuildItemsMarksMinimizedWindows() {
        let windows = [
            record(owner: "Safari", title: "Article", pid: 10, windowID: 1),
            record(owner: "Notes", title: "Plan", pid: 20, windowID: 2, isOnScreen: false, isMinimized: true)
        ]

        let items = buildTaskbarItems(windows: windows, frontmostPID: 20)

        XCTAssertEqual(items.map(\.title), ["Plan", "Article"])
        XCTAssertEqual(items.map(\.isMinimized), [true, false])
        XCTAssertFalse(items[0].isFrontmost)
    }

    func testBuildItemsMarksFrontmostAppWithoutMovingIt() {
        let windows = [
            record(owner: "Safari", title: "Article", pid: 10, windowID: 1),
            record(owner: "Terminal", title: "zsh", pid: 20, windowID: 2),
            record(owner: "Notes", title: "Planning", pid: 30, windowID: 3)
        ]

        let items = buildTaskbarItems(windows: windows, frontmostPID: 20)

        XCTAssertEqual(items.map(\.owner), ["Notes", "Safari", "Terminal"])
        XCTAssertTrue(items[2].isFrontmost)
    }

    func testBuildItemsMarksOnlyTheFrontmostWindowWhenOnePIDHasMultipleWindows() {
        let windows = [
            record(owner: "Google Chrome", title: "Inbox", pid: 739, windowID: 578),
            record(owner: "Google Chrome", title: "New tab", pid: 739, windowID: 16416)
        ]

        let items = buildTaskbarItems(
            windows: windows,
            frontmostPID: 739,
            frontmostWindowID: 16416
        )

        XCTAssertEqual(items.map(\.windowIDs), [[578], [16416]])
        XCTAssertEqual(items.map(\.isFrontmost), [false, true])
    }

    func testFrontmostWindowIDUsesFirstWindowForFrontmostPID() {
        let windows = [
            record(owner: "Google Chrome", title: "New tab", pid: 739, windowID: 16416),
            record(owner: "Google Chrome", title: "Inbox", pid: 739, windowID: 578),
            record(owner: "Slack", title: "DM", pid: 697, windowID: 49)
        ]

        XCTAssertEqual(frontmostWindowID(in: windows, frontmostPID: 739), 16416)
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

        let items = buildTaskbarItems(windows: windows, frontmostPID: nil, pinnedApps: pinned)

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

        let items = buildTaskbarItems(windows: windows, frontmostPID: nil, pinnedApps: pinned)

        XCTAssertEqual(items.map(\.owner), ["Safari", "Notes"])
        XCTAssertEqual(items[0].pid, nil)
        XCTAssertEqual(items[0].windowCount, 0)
        XCTAssertTrue(items[0].isPinned)
    }
}
