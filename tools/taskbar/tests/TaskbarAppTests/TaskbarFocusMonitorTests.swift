import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarFocusMonitorTests: XCTestCase {
    func testWorkspaceChangesTriggerRefreshAndStopRemovesObservers() {
        let center = NotificationCenter()
        var changes = 0
        let monitor = TaskbarFocusMonitor(center: center, observeAccessibility: false) { changes += 1 }
        monitor.start()
        monitor.start()
        for event in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                      NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.post(name: event, object: nil)
        }
        XCTAssertEqual(changes, 4)
        monitor.stop()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(changes, 4)
    }
}
