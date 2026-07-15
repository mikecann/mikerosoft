import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarWidgetRepaintTests: XCTestCase {
    func testRepaintTimerRunsOnlyWhenAttachedAndAWidgetIsEnabled() {
        var values = TaskbarSettingValues.defaults
        values.dateTimeWidget.isEnabled = false
        values.statsWidget.isEnabled = false

        XCTAssertFalse(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: true))

        values.dateTimeWidget.isEnabled = true
        XCTAssertTrue(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: true))
        XCTAssertFalse(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: false))

        values.dateTimeWidget.isEnabled = false
        values.statsWidget.isEnabled = true
        XCTAssertTrue(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: true))
        XCTAssertFalse(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: false))
    }

    func testAttachedWidgetRepaintsWithoutItemChangesDuringEventTracking() {
        _ = NSApplication.shared

        var values = TaskbarSettingValues.defaults
        values.dateTimeWidget.isEnabled = true
        values.statsWidget.isEnabled = false

        let frame = NSRect(x: 0, y: 0, width: 800, height: 54)
        let taskbarView = TaskbarView(frame: frame)
        taskbarView.settings = values
        var repaintRequestCount = 0
        let containerView = TaskbarContainerView(
            frame: frame,
            taskbarView: taskbarView,
            requestWidgetRepaint: { _ in repaintRequestCount += 1 }
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = containerView
        defer { window.contentView = nil }
        XCTAssertNotNil(containerView.window)

        let didRequestRepaint = waitForCondition(timeout: 1.5) {
            repaintRequestCount > 0
        }

        XCTAssertTrue(didRequestRepaint)
    }

    func testDetachedContainerStopsRequestingWidgetRepaints() {
        _ = NSApplication.shared

        var values = TaskbarSettingValues.defaults
        values.dateTimeWidget.isEnabled = true
        values.statsWidget.isEnabled = false

        let frame = NSRect(x: 0, y: 0, width: 800, height: 54)
        let taskbarView = TaskbarView(frame: frame)
        taskbarView.settings = values
        var repaintRequestCount = 0
        let containerView = TaskbarContainerView(
            frame: frame,
            taskbarView: taskbarView,
            requestWidgetRepaint: { _ in repaintRequestCount += 1 }
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = containerView

        window.contentView = nil
        let repaintCountAtDetach = repaintRequestCount

        XCTAssertFalse(
            waitForCondition(timeout: 1.5) {
                repaintRequestCount > repaintCountAtDetach
            }
        )
    }

    func testClosingPanelDetachesWidgetRepaintDriver() {
        _ = NSApplication.shared

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let screen = ScreenInfo(
            id: 1,
            name: "Test Display",
            appKitFrame: frame,
            quartzFrame: frame
        )
        let taskbarPanel = TaskbarPanel(
            screen: screen,
            values: .defaults,
            controller: TaskbarController()
        )
        XCTAssertNotNil(taskbarPanel.containerView.window)

        taskbarPanel.close()

        XCTAssertNil(taskbarPanel.containerView.window)
    }

    func testHiddenPanelStillAppliesDisabledWidgetSettings() {
        _ = NSApplication.shared

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let screen = ScreenInfo(
            id: 1,
            name: "Test Display",
            appKitFrame: frame,
            quartzFrame: frame
        )
        let taskbarPanel = TaskbarPanel(
            screen: screen,
            values: .defaults,
            controller: TaskbarController()
        )
        defer { taskbarPanel.close() }
        var values = TaskbarSettingValues.defaults
        values.isVisible = false
        values.dateTimeWidget.isEnabled = false
        values.statsWidget.isEnabled = false

        taskbarPanel.update(screen: screen, items: [], values: values)

        XCTAssertFalse(
            shouldRunTaskbarWidgetRepaintTimer(
                values: taskbarPanel.view.settings,
                isAttachedToWindow: taskbarPanel.containerView.window != nil
            )
        )
    }

    private func waitForCondition(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            _ = RunLoop.main.run(
                mode: .eventTracking,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
            if condition() {
                return true
            }
        } while Date() < deadline
        return false
    }
}
