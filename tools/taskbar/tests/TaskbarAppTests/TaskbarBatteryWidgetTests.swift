import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarBatteryWidgetTests: XCTestCase {
    func testBatterySnapshotConvertsCapacityToPercentageAndRemainingTime() throws {
        let snapshot = try XCTUnwrap(BatterySnapshot(powerSourceDescription: [
            "Is Present": true,
            "Current Capacity": 47,
            "Max Capacity": 80,
            "Is Charging": false,
            "Power Source State": "Battery Power",
            "Time to Empty": 125,
            "Name": "InternalBattery-0"
        ]))

        XCTAssertEqual(snapshot.percentage, 59)
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertFalse(snapshot.isPluggedIn)
        XCTAssertEqual(snapshot.timeRemainingMinutes, 125)
        XCTAssertEqual(snapshot.name, "InternalBattery-0")
    }

    func testChargingBatteryUsesTimeToFullAndClampsReportedCapacity() throws {
        let snapshot = try XCTUnwrap(BatterySnapshot(powerSourceDescription: [
            "Is Present": true,
            "Current Capacity": 105,
            "Max Capacity": 100,
            "Is Charging": true,
            "Power Source State": "AC Power",
            "Time to Full Charge": 42
        ]))

        XCTAssertEqual(snapshot.percentage, 100)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertTrue(snapshot.isPluggedIn)
        XCTAssertEqual(snapshot.timeRemainingMinutes, 42)
    }

    func testAbsentOrInvalidBatteryIsIgnored() {
        XCTAssertNil(BatterySnapshot(powerSourceDescription: [
            "Is Present": false,
            "Current Capacity": 50,
            "Max Capacity": 100
        ]))
        XCTAssertNil(BatterySnapshot(powerSourceDescription: [
            "Is Present": true,
            "Current Capacity": 50,
            "Max Capacity": 0
        ]))
    }

    func testBatteryWidgetTextAndSymbolReflectExactLevelAndChargingState() {
        let low = BatterySnapshot(
            percentage: 12,
            isCharging: false,
            isPluggedIn: false,
            timeRemainingMinutes: 30,
            name: "Battery"
        )
        let charging = BatterySnapshot(
            percentage: 76,
            isCharging: true,
            isPluggedIn: true,
            timeRemainingMinutes: 20,
            name: "Battery"
        )

        XCTAssertEqual(batteryWidgetText(snapshot: low), "12%")
        XCTAssertEqual(batteryWidgetSymbolName(snapshot: low), "battery.0")
        XCTAssertEqual(batteryWidgetText(snapshot: charging), "76%")
        XCTAssertEqual(batteryWidgetSymbolName(snapshot: charging), "battery.100.bolt")
    }

    func testBatteryWidgetIsInstalledBeforeDateAndTimeAndEnabledByDefault() {
        XCTAssertEqual(installedTaskbarWidgetIDs(), [.stats, .battery, .dateTime])
        XCTAssertTrue(TaskbarSettingValues.defaults.batteryWidget.isEnabled)
        XCTAssertEqual(activeTaskbarWidgets(for: .defaults).map(\.id), [.stats, .battery, .dateTime])
    }

    func testBatterySettingsDefaultWhenOlderTaskbarSettingsDoNotContainBatteryKey() throws {
        let existing = TaskbarSettingValues.defaults
        let encoded = try JSONEncoder().encode(existing)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "batteryWidget")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TaskbarSettingValues.self, from: oldData)

        XCTAssertEqual(decoded.batteryWidget, .defaults)
    }

    func testBatteryMonitorCachesNativeReadsForRefreshInterval() throws {
        var loadCount = 0
        let monitor = TaskbarBatteryMonitor(refreshInterval: 15) {
            loadCount += 1
            return BatterySnapshot(
                percentage: 50 + loadCount,
                isCharging: false,
                isPluggedIn: false,
                timeRemainingMinutes: nil,
                name: "Battery"
            )
        }
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(try XCTUnwrap(monitor.snapshot(now: start)).percentage, 51)
        XCTAssertEqual(try XCTUnwrap(monitor.snapshot(now: start.addingTimeInterval(14))).percentage, 51)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(try XCTUnwrap(monitor.snapshot(now: start.addingTimeInterval(15))).percentage, 52)
        XCTAssertEqual(loadCount, 2)
    }

    func testBatteryStatusTextExplainsPowerAndRemainingTime() {
        let snapshot = BatterySnapshot(
            percentage: 59,
            isCharging: false,
            isPluggedIn: false,
            timeRemainingMinutes: 125,
            name: "Battery"
        )

        XCTAssertEqual(batteryWidgetStatusText(snapshot: snapshot), "59% - on battery, 2h 5m remaining")
        XCTAssertEqual(batteryWidgetStatusText(snapshot: nil), "No internal battery detected")
    }
}
