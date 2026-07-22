import AppKit
import XCTest
@testable import TaskbarApp

private func visibleText(in view: NSView) -> [String] {
    let ownText = (view as? NSTextField).map { [$0.stringValue] } ?? []
    return ownText + view.subviews.flatMap(visibleText(in:))
}

private func button(actionNamed actionName: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton,
       let action = button.action,
       NSStringFromSelector(action) == actionName {
        return button
    }
    return view.subviews.lazy.compactMap { button(actionNamed: actionName, in: $0) }.first
}

private func colorWell(identifier: String, in view: NSView) -> NSColorWell? {
    if let colorWell = view as? NSColorWell,
       colorWell.identifier?.rawValue == identifier {
        return colorWell
    }
    return view.subviews.lazy.compactMap { colorWell(identifier: identifier, in: $0) }.first
}

final class SettingsWindowControllerTests: XCTestCase {
    func testUpdateScreensKeepsMonitorWidgetSelectedWhenScreenGeometryChanges() throws {
        let original = ScreenInfo(
            id: 7,
            name: "Studio Display",
            appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            quartzFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let resized = ScreenInfo(
            id: 7,
            name: "Studio Display",
            appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            quartzFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        let controller = SettingsWindowController(settings: settings, screens: [original])
        controller.selectWidget(.stats, screenID: original.id)

        controller.updateScreens([resized])

        let contentView = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(visibleText(in: contentView).contains("Studio Display override for the Stats widget."))
    }

    func testUpdateScreensLeavesNoEditablePageForDepartedMonitor() throws {
        let departed = ScreenInfo(id: 7, name: "Departed Display", appKitFrame: .zero, quartzFrame: .zero)
        let remaining = ScreenInfo(id: 8, name: "Built-in Display", appKitFrame: .zero, quartzFrame: .zero)
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        let controller = SettingsWindowController(settings: settings, screens: [departed, remaining])
        controller.selectMonitor(screenID: departed.id)

        controller.updateScreens([remaining])

        let contentView = try XCTUnwrap(controller.window?.contentView)
        let text = visibleText(in: contentView)
        XCTAssertTrue(text.contains("Defaults used by every monitor unless that monitor has an override."))
        XCTAssertFalse(text.contains("Departed Display"))
    }

    func testUpdateScreensKeepsMonitorSelectedWhenEarlierRowsAreInserted() throws {
        let selected = ScreenInfo(id: 8, name: "Selected Display", appKitFrame: .zero, quartzFrame: .zero)
        let inserted = ScreenInfo(id: 7, name: "Inserted Display", appKitFrame: .zero, quartzFrame: .zero)
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        let controller = SettingsWindowController(settings: settings, screens: [selected])
        controller.selectMonitor(screenID: selected.id)

        controller.updateScreens([inserted, selected])

        let contentView = try XCTUnwrap(controller.window?.contentView)
        let text = visibleText(in: contentView)
        XCTAssertTrue(text.contains("Selected Display"))
        XCTAssertFalse(text.contains("Inserted Display"))
    }

    func testExternalSettingsChangeRerendersTheVisibleWidgetPage() throws {
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        settings.updateGeneral { $0.statsWidget.isEnabled = true }
        let controller = SettingsWindowController(settings: settings, screens: [])
        controller.selectWidget(.stats)
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let originalCheckbox = try XCTUnwrap(button(actionNamed: "setGeneralStatsEnabled:", in: contentView))
        XCTAssertEqual(originalCheckbox.state, .on)

        settings.updateGeneral { $0.statsWidget.isEnabled = false }

        let refreshedCheckbox = try XCTUnwrap(button(actionNamed: "setGeneralStatsEnabled:", in: contentView))
        XCTAssertEqual(refreshedCheckbox.state, .off)
        XCTAssertFalse(refreshedCheckbox === originalCheckbox)
    }

    func testExternalSettingsChangeUpdatesOverrideOnVisibleMonitorWidgetPage() throws {
        let screen = ScreenInfo(id: 7, name: "Studio Display", appKitFrame: .zero, quartzFrame: .zero)
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        let controller = SettingsWindowController(settings: settings, screens: [screen])
        controller.selectWidget(.stats, screenID: screen.id)
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let originalOverride = try XCTUnwrap(button(actionNamed: "toggleMonitorStatsOverride:", in: contentView))
        XCTAssertEqual(originalOverride.state, .off)

        var externalValue = StatsWidgetSettings.defaults
        externalValue.isEnabled = false
        settings.updateOverrides(for: screen.id) { $0.statsWidget = externalValue }

        let refreshedOverride = try XCTUnwrap(button(actionNamed: "toggleMonitorStatsOverride:", in: contentView))
        let refreshedEnabled = try XCTUnwrap(button(actionNamed: "setMonitorStatsEnabled:", in: contentView))
        XCTAssertEqual(refreshedOverride.state, .on)
        XCTAssertEqual(refreshedEnabled.state, .off)
        XCTAssertFalse(refreshedOverride === originalOverride)
    }

    func testSettingsWindowMutationDoesNotSynchronouslyReplaceItsOriginatingControl() throws {
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        settings.updateGeneral { $0.statsWidget.isEnabled = true }
        let controller = SettingsWindowController(settings: settings, screens: [])
        controller.selectWidget(.stats)
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let checkbox = try XCTUnwrap(button(actionNamed: "setGeneralStatsEnabled:", in: contentView))
        checkbox.state = .off

        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(checkbox.action), to: checkbox.target, from: checkbox))

        XCTAssertFalse(settings.preferences.general.statsWidget.isEnabled)
        XCTAssertTrue(button(actionNamed: "setGeneralStatsEnabled:", in: contentView) === checkbox)
    }

    func testStatsSettingsColourWellUpdatesThePerformanceCoreColour() throws {
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        let controller = SettingsWindowController(settings: settings, screens: [])
        controller.selectWidget(.stats)
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let performance = try XCTUnwrap(colorWell(identifier: "stats-performance-core-color", in: contentView))
        performance.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)

        XCTAssertTrue(
            NSApplication.shared.sendAction(
                try XCTUnwrap(performance.action),
                to: performance.target,
                from: performance
            )
        )

        XCTAssertEqual(settings.preferences.general.statsWidget.cpuCoreColors.performance, "#336699")
    }

    func testBatterySettingsPageUpdatesTheDefaultWidgetState() throws {
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        let controller = SettingsWindowController(settings: settings, screens: [])
        controller.selectWidget(.battery)
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let checkbox = try XCTUnwrap(button(actionNamed: "setGeneralBatteryEnabled:", in: contentView))
        XCTAssertEqual(checkbox.state, .on)
        checkbox.state = .off

        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(checkbox.action), to: checkbox.target, from: checkbox))

        XCTAssertFalse(settings.preferences.general.batteryWidget.isEnabled)
    }

    func testClosingWindowStopsExternalSettingsRerenders() throws {
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        settings.updateGeneral { $0.statsWidget.isEnabled = true }
        let controller = SettingsWindowController(settings: settings, screens: [])
        controller.selectWidget(.stats)
        controller.showWindow(nil)
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let checkbox = try XCTUnwrap(button(actionNamed: "setGeneralStatsEnabled:", in: contentView))

        controller.window?.close()
        settings.updateGeneral { $0.statsWidget.isEnabled = false }

        XCTAssertTrue(button(actionNamed: "setGeneralStatsEnabled:", in: contentView) === checkbox)
        XCTAssertEqual(checkbox.state, .on)
    }
}

private final class RecordingSettingsStore: TaskbarSettingsStoring {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data, forKey key: String) {}
}

private final class RecordingTaskbarSettingsWindow: TaskbarSettingsWindow {
    var onClose: (() -> Void)?
    private(set) var screenUpdates: [[ScreenInfo]] = []

    func updateScreens(_ screens: [ScreenInfo]) {
        screenUpdates.append(screens)
    }

    func selectMonitor(screenID: UInt32) {}
    func selectWidget(_ widgetID: TaskbarWidgetID, screenID: UInt32?) {}
    func showWindow(_ sender: Any?) {}
    func close() { onClose?() }
}

final class TaskbarControllerScreenChangeTests: XCTestCase {
    func testScreenParameterChangeUpdatesOpenSettingsAndRefreshesImmediately() {
        let notificationCenter = NotificationCenter()
        let initial = ScreenInfo(id: 1, name: "Display", appKitFrame: .zero, quartzFrame: .zero)
        let resized = ScreenInfo(
            id: 1,
            name: "Display",
            appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            quartzFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        var currentScreens = [initial]
        var refreshCount = 0
        let settingsWindow = RecordingTaskbarSettingsWindow()
        let controller = TaskbarController(
            settings: TaskbarSettings(store: RecordingSettingsStore()),
            startAtLoginSync: { _ in },
            performFullRefresh: { refreshCount += 1 },
            screenCollector: { currentScreens },
            screenNotificationCenter: notificationCenter,
            settingsWindowFactory: { _, _ in settingsWindow }
        )
        controller.showSettings()
        currentScreens = [resized]

        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(settingsWindow.screenUpdates, [[resized]])
        XCTAssertEqual(refreshCount, 1)
    }

    func testScreenObserverIsRemovedAndReinstalledAcrossWindowCloseCycles() {
        let notificationCenter = NotificationCenter()
        let screen = ScreenInfo(id: 1, name: "Display", appKitFrame: .zero, quartzFrame: .zero)
        var refreshCount = 0
        var settingsWindows: [RecordingTaskbarSettingsWindow] = []
        let controller = TaskbarController(
            settings: TaskbarSettings(store: RecordingSettingsStore()),
            startAtLoginSync: { _ in },
            performFullRefresh: { refreshCount += 1 },
            screenCollector: { [screen] },
            screenNotificationCenter: notificationCenter,
            settingsWindowFactory: { _, _ in
                let window = RecordingTaskbarSettingsWindow()
                settingsWindows.append(window)
                return window
            }
        )

        controller.showSettings()
        settingsWindows[0].close()
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(refreshCount, 0)

        controller.showSettings()
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(settingsWindows.count, 2)
        XCTAssertEqual(settingsWindows[0].screenUpdates.count, 0)
        XCTAssertEqual(settingsWindows[1].screenUpdates, [[screen]])
        XCTAssertEqual(refreshCount, 1)
    }
}
