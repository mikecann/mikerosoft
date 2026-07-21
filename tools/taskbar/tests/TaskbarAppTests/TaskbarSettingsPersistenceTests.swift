import AppKit
import Foundation
import XCTest
@testable import TaskbarApp

private final class RecordingTaskbarSettingsStore: TaskbarSettingsStoring {
    struct Write {
        let key: String
        let data: Data
    }

    private(set) var dataByKey: [String: Data]
    private(set) var writes: [Write] = []
    var writeCount: Int { writes.count }
    var onFirstWrite: (() -> Void)?

    init(dataByKey: [String: Data] = [:]) {
        self.dataByKey = dataByKey
    }

    func data(forKey key: String) -> Data? {
        dataByKey[key]
    }

    func set(_ data: Data, forKey key: String) {
        dataByKey[key] = data
        writes.append(Write(key: key, data: data))
        if writeCount == 1 {
            onFirstWrite?()
        }
    }
}

private func taskbarItem(
    owner: String,
    bundleID: String,
    appPath: String,
    isPinned: Bool = false,
    pinOrder: Int? = nil
) -> TaskbarItem {
    TaskbarItem(
        owner: owner,
        pid: nil,
        title: "",
        windowCount: 0,
        windowIDs: [],
        windowBounds: nil,
        accessibilitySignature: "",
        isFrontmost: false,
        isMinimized: false,
        bundleID: bundleID,
        appPath: appPath,
        isPinned: isPinned,
        pinOrder: pinOrder
    )
}

final class TaskbarSettingsPersistenceTests: XCTestCase {
    private func performMenuItem(_ item: NSMenuItem, on controller: TaskbarController) throws {
        _ = controller.perform(try XCTUnwrap(item.action), with: item)
    }

    func testCorruptSettingsAreBackedUpBeforePrimaryIsOverwritten() {
        let primaryKey = "taskbarPreferences.v1"
        let backupKey = "taskbarPreferences.v1.corruptBackup"
        let corruptData = Data("{not-json".utf8)
        let store = RecordingTaskbarSettingsStore(dataByKey: [primaryKey: corruptData])

        let settings = TaskbarSettings(store: store)

        XCTAssertEqual(store.writes.map(\.key), [backupKey])
        XCTAssertEqual(store.dataByKey[backupKey], corruptData)

        settings.updateGeneral { $0.taskbarHeight = 72 }
        settings.flushPendingPersistence()

        XCTAssertEqual(store.writes.map(\.key), [backupKey, primaryKey])
        XCTAssertEqual(store.dataByKey[backupKey], corruptData)
        XCTAssertNotEqual(store.dataByKey[primaryKey], corruptData)
    }

    func testUpdateGeneralClampsBeforeSendingOneChangeNotification() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var changeCount = 0
        let observation = settings.observeChanges { changeCount += 1 }

        settings.updateGeneral { values in
            values.taskbarHeight = 120
        }

        XCTAssertEqual(settings.preferences.general.taskbarHeight, 96)
        XCTAssertEqual(changeCount, 1)
        settings.flushPendingPersistence()
        XCTAssertEqual(store.writeCount, 1)
        withExtendedLifetime(observation) {}
    }

    func testUpdateGeneralDoesNotNotifyWhenTransformMakesNoChange() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var changeCount = 0
        let observation = settings.observeChanges { changeCount += 1 }

        settings.updateGeneral { _ in }
        settings.flushPendingPersistence()

        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(store.writeCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testSettingsChangeObserversAreMulticast() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var firstCount = 0
        var secondCount = 0
        let first = settings.observeChanges { firstCount += 1 }
        let second = settings.observeChanges { secondCount += 1 }

        settings.updateGeneral { $0.taskbarHeight = 72 }

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)
        withExtendedLifetime([first, second]) {}
    }

    func testSettingsMutationCanSuppressOnlyTheOriginatingObserver() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var originatingCount = 0
        var controllerCount = 0
        let originatingObserver = settings.observeChanges { originatingCount += 1 }
        let controllerObserver = settings.observeChanges { controllerCount += 1 }

        settings.performChanges(suppressing: originatingObserver) {
            settings.updateGeneral { $0.taskbarHeight = 72 }
        }

        XCTAssertEqual(originatingCount, 0)
        XCTAssertEqual(controllerCount, 1)
        withExtendedLifetime(controllerObserver) {}
    }

    func testUpdateOverridesDoesNotNotifyWhenTransformMakesNoChange() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var changeCount = 0
        let observation = settings.observeChanges { changeCount += 1 }

        settings.updateOverrides(for: 123) { _ in }
        settings.flushPendingPersistence()

        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(store.writeCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testSliderLikeBurstUsesOneTrailingPersistenceWrite() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let persisted = expectation(description: "settings persisted after debounce")
        store.onFirstWrite = { persisted.fulfill() }

        for value in 0..<40 {
            settings.updateGeneral { values in
                values.backgroundOpacity = 0.2 + Double(value) / 100
            }
        }

        XCTAssertEqual(store.writeCount, 0)
        wait(for: [persisted], timeout: 1)
        XCTAssertEqual(store.writeCount, 1)
    }

    func testPendingPersistenceCanBeFlushedBeforeTermination() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        settings.updateGeneral { values in
            values.taskbarHeight = 72
        }

        XCTAssertEqual(store.writeCount, 0)
        controller.prepareForTermination()

        XCTAssertEqual(store.writeCount, 1)
        controller.prepareForTermination()
        XCTAssertEqual(store.writeCount, 1)
    }

    func testStartAtLoginSyncOnlyRunsWhenFlagChanges() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var syncedValues: [Bool] = []
        settings.onStartAtLoginChange = { syncedValues.append($0) }

        settings.updateGeneral { values in
            values.backgroundOpacity = 0.5
        }
        settings.setStartAtLogin(true)
        settings.setStartAtLogin(false)
        settings.setStartAtLogin(false)

        XCTAssertEqual(syncedValues, [false])
    }

    func testPreferencesRoundTripThroughInjectedUserDefaultsSuite() {
        let suiteName = "TaskbarSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TaskbarSettings(defaults: defaults)

        settings.updateGeneral { values in
            values.taskbarHeight = 72
            values.backgroundOpacity = 0.45
        }
        settings.updateOverrides(for: 123) { override in
            override.itemSpacing = 8
        }
        settings.setStartAtLogin(false)
        settings.flushPendingPersistence()

        let reloaded = TaskbarSettings(defaults: defaults)
        XCTAssertEqual(reloaded.preferences.general.taskbarHeight, 72)
        XCTAssertEqual(reloaded.preferences.general.backgroundOpacity, 0.45)
        XCTAssertEqual(reloaded.preferences.monitorOverrides["123"]?.itemSpacing, 8)
        XCTAssertFalse(reloaded.preferences.startAtLogin)
    }

    func testControllerSyncsStartAtLoginOnlyWhenFlagChanges() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var syncedValues: [Bool] = []
        let controller = TaskbarController(
            settings: settings,
            startAtLoginSync: { syncedValues.append($0) }
        )

        withExtendedLifetime(controller) {
            settings.updateGeneral { values in
                values.taskbarHeight = 72
            }
            settings.setStartAtLogin(true)
            settings.setStartAtLogin(false)
            settings.setStartAtLogin(false)
        }

        XCTAssertEqual(syncedValues, [false])
    }

    func testControllerDefersInitialRefreshUntilWindowProviderCachesAreWarm() throws {
        let screen = ScreenInfo(id: 123, name: "Display", appKitFrame: .zero, quartzFrame: .zero)
        var warmedScreens: [ScreenInfo] = []
        var includedMinimizedWindows = false
        var finishWarmup: (() -> Void)?
        var refreshCount = 0
        let controller = TaskbarController(
            settings: TaskbarSettings(store: RecordingTaskbarSettingsStore()),
            startAtLoginSync: { _ in },
            performFullRefresh: { refreshCount += 1 },
            screenCollector: { [screen] },
            initialWindowProviderWarmup: { screens, includeMinimized, completion in
                warmedScreens = screens
                includedMinimizedWindows = includeMinimized
                finishWarmup = completion
            }
        )

        controller.start()
        controller.refresh()

        XCTAssertEqual(warmedScreens, [screen])
        XCTAssertTrue(includedMinimizedWindows)
        XCTAssertEqual(refreshCount, 0)

        try XCTUnwrap(finishWarmup)()

        XCTAssertEqual(refreshCount, 1)
        controller.prepareForTermination()
    }

    func testControllerDoesNotFinishStartingAfterTerminationDuringWindowProviderWarmup() throws {
        var finishWarmup: (() -> Void)?
        var refreshCount = 0
        let controller = TaskbarController(
            settings: TaskbarSettings(store: RecordingTaskbarSettingsStore()),
            startAtLoginSync: { _ in },
            performFullRefresh: { refreshCount += 1 },
            screenCollector: { [] },
            initialWindowProviderWarmup: { _, _, completion in
                finishWarmup = completion
            }
        )

        controller.start()
        controller.prepareForTermination()
        try XCTUnwrap(finishWarmup)()

        XCTAssertEqual(refreshCount, 0)
    }

    func testControllerSettingsRefreshRemainsRegisteredWhenAnotherListenerIsAdded() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var scheduledRefreshCount = 0
        var secondListenerCount = 0
        let controller = TaskbarController(
            settings: settings,
            startAtLoginSync: { _ in },
            scheduleSettingsRefresh: { scheduledRefreshCount += 1 }
        )
        let secondObserver = settings.observeChanges { secondListenerCount += 1 }

        settings.updateGeneral { $0.taskbarHeight = 72 }

        XCTAssertEqual(scheduledRefreshCount, 1)
        XCTAssertEqual(secondListenerCount, 1)
        withExtendedLifetime((controller, secondObserver)) {}
    }

    func testMenuSettingsMutationsEachScheduleOneRefreshWithoutImmediateFullRefresh() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var scheduledRefreshCount = 0
        var fullRefreshCount = 0
        let controller = TaskbarController(
            settings: settings,
            startAtLoginSync: { _ in },
            scheduleSettingsRefresh: { scheduledRefreshCount += 1 },
            performFullRefresh: { fullRefreshCount += 1 }
        )
        let notes = taskbarItem(
            owner: "Notes",
            bundleID: "com.apple.Notes",
            appPath: "/System/Applications/Notes.app"
        )
        let safari = taskbarItem(
            owner: "Safari",
            bundleID: "com.apple.Safari",
            appPath: "/Applications/Safari.app"
        )

        try performMenuItem(XCTUnwrap(controller.makeItemMenu(for: notes, screenID: 123).items.first), on: controller)
        XCTAssertEqual(scheduledRefreshCount, 1)
        XCTAssertEqual(fullRefreshCount, 0)

        try performMenuItem(XCTUnwrap(controller.makeItemMenu(for: safari, screenID: 123).items.first), on: controller)
        XCTAssertEqual(scheduledRefreshCount, 2)
        XCTAssertEqual(fullRefreshCount, 0)

        controller.movePinnedItem(safari, before: notes, screenID: 123)
        XCTAssertEqual(scheduledRefreshCount, 3)
        XCTAssertEqual(fullRefreshCount, 0)

        let dateTimeMenu = try XCTUnwrap(controller.makeWidgetMenu(for: .dateTime, screenID: 123))
        try performMenuItem(XCTUnwrap(dateTimeMenu.items.first), on: controller)
        XCTAssertEqual(scheduledRefreshCount, 4)
        XCTAssertEqual(fullRefreshCount, 0)

        let statsMenu = try XCTUnwrap(controller.makeWidgetMenu(for: .stats, screenID: 123))
        try performMenuItem(XCTUnwrap(statsMenu.items.first(where: { $0.title == "Show Stats" })), on: controller)
        XCTAssertEqual(scheduledRefreshCount, 5)
        XCTAssertEqual(fullRefreshCount, 0)

        XCTAssertEqual(settings.values(for: 123).pinnedApps.map(\.displayName), ["Safari", "Notes"])
    }

    func testScreenScopedPinWithoutOverrideUpdatesGeneral() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let notes = taskbarItem(
            owner: "Notes",
            bundleID: "com.apple.Notes",
            appPath: "/System/Applications/Notes.app"
        )

        let pinItem = try XCTUnwrap(controller.makeItemMenu(for: notes, screenID: 123).items.first)
        try performMenuItem(pinItem, on: controller)

        XCTAssertEqual(settings.preferences.general.pinnedApps.map(\.displayName), ["Notes"])
        XCTAssertTrue(settings.preferences.monitorOverrides.isEmpty)
    }

    func testScreenScopedUnpinWithoutOverrideUpdatesGeneral() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let notes = taskbarItem(
            owner: "Notes",
            bundleID: "com.apple.Notes",
            appPath: "/System/Applications/Notes.app",
            isPinned: true
        )
        settings.pin(PinnedApp(displayName: notes.owner, bundleID: notes.bundleID, appPath: notes.appPath))

        let unpinItem = try XCTUnwrap(controller.makeItemMenu(for: notes, screenID: 123).items.first)
        try performMenuItem(unpinItem, on: controller)

        XCTAssertTrue(settings.preferences.general.pinnedApps.isEmpty)
        XCTAssertTrue(settings.preferences.monitorOverrides.isEmpty)
    }

    func testScreenScopedReorderWithoutOverrideUpdatesGeneral() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let notes = taskbarItem(
            owner: "Notes",
            bundleID: "com.apple.Notes",
            appPath: "/System/Applications/Notes.app",
            isPinned: true,
            pinOrder: 0
        )
        let safari = taskbarItem(
            owner: "Safari",
            bundleID: "com.apple.Safari",
            appPath: "/Applications/Safari.app",
            isPinned: true,
            pinOrder: 1
        )
        settings.pin(PinnedApp(displayName: notes.owner, bundleID: notes.bundleID, appPath: notes.appPath))
        settings.pin(PinnedApp(displayName: safari.owner, bundleID: safari.bundleID, appPath: safari.appPath))

        controller.movePinnedItem(safari, before: notes, screenID: 123)

        XCTAssertEqual(settings.preferences.general.pinnedApps.map(\.displayName), ["Safari", "Notes"])
        XCTAssertTrue(settings.preferences.monitorOverrides.isEmpty)
    }

    func testScreenScopedPinnedAppActionsUpdateExistingOverrideOnly() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let notes = PinnedApp(
            displayName: "Notes",
            bundleID: "com.apple.Notes",
            appPath: "/System/Applications/Notes.app"
        )
        let calendar = taskbarItem(
            owner: "Calendar",
            bundleID: "com.apple.iCal",
            appPath: "/System/Applications/Calendar.app"
        )
        let safari = taskbarItem(
            owner: "Safari",
            bundleID: "com.apple.Safari",
            appPath: "/Applications/Safari.app"
        )
        settings.pin(notes)
        settings.updateOverrides(for: 123) { $0.pinnedApps = [] }

        let pinCalendarItem = try XCTUnwrap(controller.makeItemMenu(for: calendar, screenID: 123).items.first)
        try performMenuItem(pinCalendarItem, on: controller)
        let pinSafariItem = try XCTUnwrap(controller.makeItemMenu(for: safari, screenID: 123).items.first)
        try performMenuItem(pinSafariItem, on: controller)

        let pinnedCalendar = taskbarItem(
            owner: calendar.owner,
            bundleID: calendar.bundleID,
            appPath: calendar.appPath,
            isPinned: true,
            pinOrder: 0
        )
        let pinnedSafari = taskbarItem(
            owner: safari.owner,
            bundleID: safari.bundleID,
            appPath: safari.appPath,
            isPinned: true,
            pinOrder: 1
        )
        controller.movePinnedItem(pinnedSafari, before: pinnedCalendar, screenID: 123)

        let unpinCalendarItem = try XCTUnwrap(controller.makeItemMenu(for: pinnedCalendar, screenID: 123).items.first)
        try performMenuItem(unpinCalendarItem, on: controller)

        XCTAssertEqual(settings.preferences.general.pinnedApps.map(\.displayName), ["Notes"])
        XCTAssertEqual(
            settings.preferences.monitorOverrides["123"]?.pinnedApps?.map(\.displayName),
            ["Safari"]
        )
    }

    func testScreenScopedPinnedAppActionsUpdateExistingNonemptyOverrideOnly() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let finder = taskbarItem(
            owner: "Finder",
            bundleID: "com.apple.finder",
            appPath: "/System/Library/CoreServices/Finder.app",
            isPinned: true,
            pinOrder: 0
        )
        settings.updateOverrides(for: 123) {
            $0.pinnedApps = [PinnedApp(displayName: finder.owner, bundleID: finder.bundleID, appPath: finder.appPath)]
        }

        let unpinFinderItem = try XCTUnwrap(controller.makeItemMenu(for: finder, screenID: 123).items.first)
        try performMenuItem(unpinFinderItem, on: controller)

        XCTAssertTrue(settings.preferences.general.pinnedApps.isEmpty)
        XCTAssertEqual(settings.preferences.monitorOverrides["123"]?.pinnedApps, [])
    }

    func testDateTimeMenuWithoutOverrideUpdatesGeneral() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })

        let menu = try XCTUnwrap(controller.makeWidgetMenu(for: .dateTime, screenID: 123))
        let showDateTimeItem = try XCTUnwrap(menu.items.first)
        try performMenuItem(showDateTimeItem, on: controller)

        XCTAssertFalse(settings.preferences.general.dateTimeWidget.isEnabled)
        XCTAssertTrue(settings.preferences.monitorOverrides.isEmpty)
    }

    func testDateTimeMenuWithOverrideUpdatesOverrideOnly() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let monitorValue = DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .always,
            showDayOfWeek: false,
            showSeconds: false,
            use24HourClock: false
        )
        settings.updateOverrides(for: 123) { $0.dateTimeWidget = monitorValue }

        let menu = try XCTUnwrap(controller.makeWidgetMenu(for: .dateTime, screenID: 123))
        let showSecondsItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Show Seconds" }))
        try performMenuItem(showSecondsItem, on: controller)

        var expected = monitorValue
        expected.showSeconds = true
        XCTAssertEqual(settings.preferences.general.dateTimeWidget, .defaults)
        XCTAssertEqual(settings.preferences.monitorOverrides["123"]?.dateTimeWidget, expected)
    }

    func testDateTimeMenuMigratesLegacyClockModeOverride() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        settings.updateGeneral { values in
            values.dateTimeWidget.showDayOfWeek = false
            values.dateTimeWidget.showSeconds = true
            values.dateTimeWidget.use24HourClock = false
        }
        let generalValue = settings.preferences.general.dateTimeWidget
        settings.updateOverrides(for: 123) { $0.clockMode = .time }

        let menu = try XCTUnwrap(controller.makeWidgetMenu(for: .dateTime, screenID: 123))
        let showSecondsItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Show Seconds" }))
        try performMenuItem(showSecondsItem, on: controller)

        var expected = generalValue
        expected.applyLegacyClockMode(.time)
        expected.showSeconds.toggle()
        XCTAssertEqual(settings.preferences.general.dateTimeWidget, generalValue)
        XCTAssertNil(settings.preferences.monitorOverrides["123"]?.clockMode)
        XCTAssertEqual(settings.preferences.monitorOverrides["123"]?.dateTimeWidget, expected)
    }

    func testStatsMenuWithoutOverrideUpdatesGeneral() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })

        let menu = try XCTUnwrap(controller.makeWidgetMenu(for: .stats, screenID: 123))
        let showStatsItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Show Stats" }))
        try performMenuItem(showStatsItem, on: controller)

        XCTAssertFalse(settings.preferences.general.statsWidget.isEnabled)
        XCTAssertTrue(settings.preferences.monitorOverrides.isEmpty)
    }

    func testStatsMenuWithOverrideUpdatesOverrideOnly() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let monitorValue = StatsWidgetSettings(
            isEnabled: true,
            showCPU: false,
            showGPU: false,
            showMemory: true,
            showNetwork: false,
            showMiniGraph: false,
            memoryDisplay: .pie
        )
        settings.updateOverrides(for: 123) { $0.statsWidget = monitorValue }

        let menu = try XCTUnwrap(controller.makeWidgetMenu(for: .stats, screenID: 123))
        let cpuItem = try XCTUnwrap(menu.items.first(where: { $0.title == "CPU" }))
        try performMenuItem(cpuItem, on: controller)

        var expected = monitorValue
        expected.showCPU = true
        XCTAssertEqual(settings.preferences.general.statsWidget, .defaults)
        XCTAssertEqual(settings.preferences.monitorOverrides["123"]?.statsWidget, expected)
    }

    func testStatsMenuCanSelectPerCPUDisplayMode() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })

        let menu = try XCTUnwrap(controller.makeWidgetMenu(for: .stats, screenID: 123))
        let displayItem = try XCTUnwrap(menu.items.first(where: { $0.title == "CPU Display" }))
        let perCPUItem = try XCTUnwrap(displayItem.submenu?.items.first(where: { $0.title == "Per CPU" }))
        try performMenuItem(perCPUItem, on: controller)

        XCTAssertEqual(settings.preferences.general.statsWidget.cpuDisplay, .perCPU)
    }

    func testMenuActionsUpdateGeneralWhenMonitorOnlyOverridesOtherFields() throws {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let notes = taskbarItem(
            owner: "Notes",
            bundleID: "com.apple.Notes",
            appPath: "/System/Applications/Notes.app"
        )
        settings.updateOverrides(for: 123) { $0.itemSpacing = 8 }

        try performMenuItem(
            XCTUnwrap(controller.makeItemMenu(for: notes, screenID: 123).items.first),
            on: controller
        )
        let dateTimeMenu = try XCTUnwrap(controller.makeWidgetMenu(for: .dateTime, screenID: 123))
        try performMenuItem(XCTUnwrap(dateTimeMenu.items.first), on: controller)
        let statsMenu = try XCTUnwrap(controller.makeWidgetMenu(for: .stats, screenID: 123))
        try performMenuItem(XCTUnwrap(statsMenu.items.first(where: { $0.title == "Show Stats" })), on: controller)

        XCTAssertEqual(settings.preferences.general.pinnedApps.map(\.displayName), ["Notes"])
        XCTAssertFalse(settings.preferences.general.dateTimeWidget.isEnabled)
        XCTAssertFalse(settings.preferences.general.statsWidget.isEnabled)
        XCTAssertEqual(settings.preferences.monitorOverrides["123"], TaskbarMonitorOverrides(itemSpacing: 8))
    }
}
