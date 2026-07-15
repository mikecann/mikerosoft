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
}
