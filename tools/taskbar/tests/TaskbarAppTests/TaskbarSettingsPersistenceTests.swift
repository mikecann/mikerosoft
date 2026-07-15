import AppKit
import Foundation
import XCTest
@testable import TaskbarApp

private final class RecordingTaskbarSettingsStore: TaskbarSettingsStoring {
    private(set) var data: Data?
    private(set) var writeCount = 0
    var onFirstWrite: (() -> Void)?

    func data(forKey key: String) -> Data? {
        data
    }

    func set(_ data: Data, forKey key: String) {
        self.data = data
        writeCount += 1
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
    func testUpdateGeneralClampsBeforeSendingOneChangeNotification() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var changeCount = 0
        settings.onChange = { changeCount += 1 }

        settings.updateGeneral { values in
            values.taskbarHeight = 120
        }

        XCTAssertEqual(settings.preferences.general.taskbarHeight, 96)
        XCTAssertEqual(changeCount, 1)
        settings.flushPendingPersistence()
        XCTAssertEqual(store.writeCount, 1)
    }

    func testUpdateGeneralDoesNotNotifyWhenTransformMakesNoChange() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var changeCount = 0
        settings.onChange = { changeCount += 1 }

        settings.updateGeneral { _ in }
        settings.flushPendingPersistence()

        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testUpdateOverridesDoesNotNotifyWhenTransformMakesNoChange() {
        let store = RecordingTaskbarSettingsStore()
        let settings = TaskbarSettings(store: store)
        var changeCount = 0
        settings.onChange = { changeCount += 1 }

        settings.updateOverrides(for: 123) { _ in }
        settings.flushPendingPersistence()

        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(store.writeCount, 0)
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

        func perform(_ item: NSMenuItem) throws {
            let action = try XCTUnwrap(item.action)
            _ = controller.perform(action, with: item)
        }

        try perform(XCTUnwrap(controller.makeItemMenu(for: notes, screenID: 123).items.first))
        XCTAssertEqual(scheduledRefreshCount, 1)
        XCTAssertEqual(fullRefreshCount, 0)

        try perform(XCTUnwrap(controller.makeItemMenu(for: safari, screenID: 123).items.first))
        XCTAssertEqual(scheduledRefreshCount, 2)
        XCTAssertEqual(fullRefreshCount, 0)

        controller.movePinnedItem(safari, before: notes, screenID: 123)
        XCTAssertEqual(scheduledRefreshCount, 3)
        XCTAssertEqual(fullRefreshCount, 0)

        let dateTimeMenu = try XCTUnwrap(controller.makeWidgetMenu(for: .dateTime, screenID: 123))
        try perform(XCTUnwrap(dateTimeMenu.items.first))
        XCTAssertEqual(scheduledRefreshCount, 4)
        XCTAssertEqual(fullRefreshCount, 0)

        let statsMenu = try XCTUnwrap(controller.makeWidgetMenu(for: .stats, screenID: 123))
        try perform(XCTUnwrap(statsMenu.items.first(where: { $0.title == "Show Stats" })))
        XCTAssertEqual(scheduledRefreshCount, 5)
        XCTAssertEqual(fullRefreshCount, 0)

        XCTAssertTrue(settings.isPinned(
            PinnedApp(displayName: notes.owner, bundleID: notes.bundleID, appPath: notes.appPath),
            for: 123
        ))
        XCTAssertEqual(settings.values(for: 123).pinnedApps.map(\.displayName), ["Safari", "Notes"])
    }
}
