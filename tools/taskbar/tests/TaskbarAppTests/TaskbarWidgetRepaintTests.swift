import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarWidgetRepaintTests: XCTestCase {
    func testRepaintTimerRunsOnlyWhenAttachedVisibleAndAWidgetIsEnabled() {
        var values = TaskbarSettingValues.defaults
        values.dateTimeWidget.isEnabled = false
        values.statsWidget.isEnabled = false
        values.batteryWidget.isEnabled = false

        XCTAssertFalse(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: true, isPanelVisible: true))

        values.dateTimeWidget.isEnabled = true
        XCTAssertTrue(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: true, isPanelVisible: true))
        XCTAssertFalse(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: false, isPanelVisible: true))
        XCTAssertFalse(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: true, isPanelVisible: false))

        values.dateTimeWidget.isEnabled = false
        values.statsWidget.isEnabled = true
        XCTAssertTrue(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: true, isPanelVisible: true))
        XCTAssertFalse(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: false, isPanelVisible: true))

        values.statsWidget.isEnabled = false
        values.batteryWidget.isEnabled = true
        XCTAssertTrue(shouldRunTaskbarWidgetRepaintTimer(values: values, isAttachedToWindow: true, isPanelVisible: true))
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
        containerView.setWidgetRepaintVisibility(true)
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
        containerView.setWidgetRepaintVisibility(true)

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

        let taskbarPanel = makePanel()
        XCTAssertNotNil(taskbarPanel.containerView.window)

        taskbarPanel.close()

        XCTAssertNil(taskbarPanel.containerView.window)
    }

    func testOrderedOutPanelWithEnabledWidgetDoesNotRepaint() {
        _ = NSApplication.shared

        var values = TaskbarSettingValues.defaults
        values.dateTimeWidget.isEnabled = true
        values.statsWidget.isEnabled = false
        var repaintRequestCount = 0
        let taskbarPanel = makePanel(
            values: values,
            requestWidgetRepaint: { _ in repaintRequestCount += 1 }
        )
        defer { taskbarPanel.close() }
        XCTAssertFalse(taskbarPanel.panel.isVisible)

        XCTAssertFalse(
            waitForCondition(timeout: 1.5) {
                repaintRequestCount > 0
            }
        )
    }

    func testShowingPanelStartsEnabledWidgetRepaints() {
        _ = NSApplication.shared

        let screen = testScreen
        var values = TaskbarSettingValues.defaults
        values.dateTimeWidget.isEnabled = true
        values.statsWidget.isEnabled = false
        var repaintRequestCount = 0
        let taskbarPanel = makePanel(
            values: values,
            requestWidgetRepaint: { _ in repaintRequestCount += 1 }
        )
        defer { taskbarPanel.close() }

        taskbarPanel.update(screen: screen, items: [], values: values)

        XCTAssertTrue(taskbarPanel.panel.isVisible)
        XCTAssertTrue(
            waitForCondition(timeout: 1.5) {
                repaintRequestCount > 0
            }
        )
    }

    func testVisibilityOnlyHideStopsAndShowingAgainRestartsRepaints() {
        _ = NSApplication.shared

        let screen = testScreen
        var visibleValues = TaskbarSettingValues.defaults
        visibleValues.dateTimeWidget.isEnabled = true
        visibleValues.statsWidget.isEnabled = false
        var repaintRequestCount = 0
        let taskbarPanel = makePanel(
            values: visibleValues,
            requestWidgetRepaint: { _ in repaintRequestCount += 1 }
        )
        defer { taskbarPanel.close() }
        taskbarPanel.update(screen: screen, items: [], values: visibleValues)
        XCTAssertTrue(taskbarPanel.panel.isVisible)

        var hiddenValues = visibleValues
        hiddenValues.isVisible = false
        taskbarPanel.update(screen: screen, items: [], values: hiddenValues)
        XCTAssertFalse(taskbarPanel.panel.isVisible)
        let repaintCountAtHide = repaintRequestCount

        XCTAssertFalse(
            waitForCondition(timeout: 1.5) {
                repaintRequestCount > repaintCountAtHide
            }
        )

        taskbarPanel.update(screen: screen, items: [], values: visibleValues)
        XCTAssertTrue(taskbarPanel.panel.isVisible)
        let repaintCountAtShow = repaintRequestCount

        XCTAssertTrue(
            waitForCondition(timeout: 1.5) {
                repaintRequestCount > repaintCountAtShow
            }
        )
    }

    func testHiddenPanelStillAppliesDisabledWidgetSettings() {
        _ = NSApplication.shared

        let screen = testScreen
        let taskbarPanel = makePanel()
        defer { taskbarPanel.close() }
        var values = TaskbarSettingValues.defaults
        values.isVisible = false
        values.dateTimeWidget.isEnabled = false
        values.statsWidget.isEnabled = false
        values.batteryWidget.isEnabled = false

        taskbarPanel.update(screen: screen, items: [], values: values)

        XCTAssertFalse(
            shouldRunTaskbarWidgetRepaintTimer(
                values: taskbarPanel.view.settings,
                isAttachedToWindow: taskbarPanel.containerView.window != nil,
                isPanelVisible: taskbarPanel.panel.isVisible
            )
        )
    }

    private var testScreen: ScreenInfo {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return ScreenInfo(
            id: 1,
            name: "Test Display",
            appKitFrame: frame,
            quartzFrame: frame
        )
    }

    private func makePanel(
        values: TaskbarSettingValues = .defaults,
        requestWidgetRepaint: @escaping (TaskbarView) -> Void = { _ in }
    ) -> TaskbarPanel {
        TaskbarPanel(
            screen: testScreen,
            values: values,
            controller: TaskbarController(),
            requestWidgetRepaint: requestWidgetRepaint
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
