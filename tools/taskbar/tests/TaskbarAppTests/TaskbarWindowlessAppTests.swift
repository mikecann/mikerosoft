import XCTest
@testable import TaskbarApp

final class TaskbarWindowlessAppTests: XCTestCase {
    func testRunningAppWithoutWindowsIsCompactAndReopensOnClick() throws {
        let app = TaskbarRunningApp(name: "Preview", pid: 42, bundleID: "com.apple.Preview", appPath: "/Applications/Preview.app")
        let items = buildTaskbarItems(windows: [], frontmostPID: 42, runningApps: [app])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.pid, 42)
        XCTAssertTrue(item.isFrontmost)
        XCTAssertFalse(taskbarItemShowsLabel(item))
        XCTAssertEqual(taskbarItemClickAction(for: item), .launch)
    }

    func testRunningPinnedAppDoesNotAlsoCreateClosedLauncher() {
        let app = TaskbarRunningApp(name: "Preview", pid: 42, bundleID: "com.apple.Preview", appPath: "/Applications/Preview.app")
        let items = buildTaskbarItems(windows: [], frontmostPID: nil,
            pinnedApps: [PinnedApp(displayName: app.name, bundleID: app.bundleID, appPath: app.appPath)], runningApps: [app])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.pid, 42)
        XCTAssertEqual(items.first?.isPinned, true)
    }

    func testAppsWithWindowsOnAnotherMonitorDoNotGetWindowlessButtons() {
        let app = TaskbarRunningApp(name: "Preview", pid: 42, bundleID: "com.apple.Preview", appPath: "/Applications/Preview.app")
        XCTAssertTrue(taskbarWindowlessApps([app], representedPIDs: [42]).isEmpty)
        XCTAssertEqual(taskbarWindowlessApps([app], representedPIDs: []).count, 1)
    }
}
