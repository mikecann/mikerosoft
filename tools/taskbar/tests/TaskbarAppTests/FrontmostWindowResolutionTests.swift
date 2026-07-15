import CoreGraphics
import XCTest
@testable import TaskbarApp

final class FrontmostWindowResolutionTests: XCTestCase {
    func taskbarItem(
        pid: pid_t? = 739,
        windowIDs: [Int] = [16_416],
        isMinimized: Bool = false
    ) -> TaskbarItem {
        TaskbarItem(
            owner: "Google Chrome",
            pid: pid,
            title: "New tab",
            windowCount: windowIDs.count,
            windowIDs: windowIDs,
            windowBounds: nil,
            accessibilitySignature: "profile-window",
            isFrontmost: false,
            isMinimized: isMinimized,
            bundleID: "com.google.Chrome",
            appPath: "/Applications/Google Chrome.app",
            isPinned: false,
            pinOrder: nil
        )
    }

    func windowRecord(title: String, windowID: Int) -> WindowRecord {
        WindowRecord(
            owner: "Google Chrome",
            title: title,
            pid: 739,
            windowID: windowID,
            accessibilityWindowID: windowID,
            layer: 0,
            isOnScreen: true,
            isMinimized: false,
            bounds: CGRect(x: windowID, y: 0, width: 800, height: 600),
            screenID: 1,
            bundleID: "com.google.Chrome",
            appPath: "/Applications/Google Chrome.app",
            accessibilityTitle: title,
            accessibilitySignature: ""
        )
    }

    func testNoExpectationLeavesMeasuredWindowUnchanged() {
        let resolution = resolveFrontmostWindow(
            measuredPID: 739,
            measuredWindowID: 578,
            expectation: nil,
            now: 10
        )

        XCTAssertEqual(resolution.effectiveWindowID, 578)
        XCTAssertNil(resolution.remainingExpectation)
    }

    func testExpiredExpectationYieldsMeasuredWindowAndClearsExpectation() {
        let expectation = FrontmostWindowExpectation(pid: 739, windowID: 16_416, expiresAt: 12)

        let resolution = resolveFrontmostWindow(
            measuredPID: 739,
            measuredWindowID: 578,
            expectation: expectation,
            now: 12
        )

        XCTAssertEqual(resolution.effectiveWindowID, 578)
        XCTAssertNil(resolution.remainingExpectation)
    }

    func testConfirmedExpectationYieldsMeasuredWindowAndClearsExpectation() {
        let expectation = FrontmostWindowExpectation(pid: 739, windowID: 16_416, expiresAt: 12)

        let resolution = resolveFrontmostWindow(
            measuredPID: 739,
            measuredWindowID: 16_416,
            expectation: expectation,
            now: 10
        )

        XCTAssertEqual(resolution.effectiveWindowID, 16_416)
        XCTAssertNil(resolution.remainingExpectation)
    }

    func testUnconfirmedWindowForExpectedPIDUsesOptimisticWindowAndKeepsExpectation() {
        let expectation = FrontmostWindowExpectation(pid: 739, windowID: 16_416, expiresAt: 12)

        let resolution = resolveFrontmostWindow(
            measuredPID: 739,
            measuredWindowID: 578,
            expectation: expectation,
            now: 10
        )

        XCTAssertEqual(resolution.effectiveWindowID, 16_416)
        XCTAssertEqual(resolution.remainingExpectation, expectation)
    }

    func testDifferentMeasuredPIDYieldsMeasuredWindowAndKeepsExpectation() {
        let expectation = FrontmostWindowExpectation(pid: 739, windowID: 16_416, expiresAt: 12)

        let resolution = resolveFrontmostWindow(
            measuredPID: 697,
            measuredWindowID: 49,
            expectation: expectation,
            now: 10
        )

        XCTAssertEqual(resolution.effectiveWindowID, 49)
        XCTAssertEqual(resolution.remainingExpectation, expectation)
    }

    func testActivatingMinimizedWindowCreatesTwoSecondExpectation() {
        let item = taskbarItem(isMinimized: true)

        let expectation = frontmostWindowExpectation(afterActivating: item, now: 10)

        XCTAssertEqual(
            expectation,
            FrontmostWindowExpectation(pid: 739, windowID: 16_416, expiresAt: 12)
        )
    }

    func testActivatingNotRunningPinnedAppCreatesNoExpectation() {
        let item = taskbarItem(pid: nil, windowIDs: [])

        XCTAssertNil(frontmostWindowExpectation(afterActivating: item, now: 10))
    }

    func testResolvedOptimisticWindowIDMarksClickedTaskbarItemFrontmost() {
        let windows = [
            windowRecord(title: "Inbox", windowID: 578),
            windowRecord(title: "New tab", windowID: 16_416)
        ]
        let expectation = FrontmostWindowExpectation(pid: 739, windowID: 16_416, expiresAt: 12)
        let resolution = resolveFrontmostWindow(
            measuredPID: 739,
            measuredWindowID: 578,
            expectation: expectation,
            now: 10
        )

        let items = buildTaskbarItems(
            windows: windows,
            frontmostPID: 739,
            frontmostWindowID: resolution.effectiveWindowID
        )

        XCTAssertEqual(items.map(\.windowIDs), [[578], [16_416]])
        XCTAssertEqual(items.map(\.isFrontmost), [false, true])
    }
}
