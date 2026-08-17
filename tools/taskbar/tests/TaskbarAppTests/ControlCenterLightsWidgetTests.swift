import XCTest
@testable import TaskbarApp

final class ControlCenterLightsWidgetTests: XCTestCase {
    func testToggleTurnsAllLightsOffOnlyWhenEveryReachableLightIsOn() {
        XCTAssertEqual(controlCenterLightsToggleTarget(for: [true, true]), false)
        XCTAssertEqual(controlCenterLightsToggleTarget(for: [true, false]), true)
        XCTAssertEqual(controlCenterLightsToggleTarget(for: [false, false]), true)
        XCTAssertNil(controlCenterLightsToggleTarget(for: []))
    }

    func testLightStateResponseReadsThePowerStateWithoutDependingOnOtherSettings() throws {
        let data = Data(#"{"numberOfLights":1,"lights":[{"on":1,"brightness":42,"temperature":218}]}"#.utf8)

        XCTAssertTrue(try controlCenterLightPowerState(from: data))
    }

    func testPowerRequestOnlyChangesPower() throws {
        let data = try controlCenterLightPowerRequestData(isOn: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lights = try XCTUnwrap(object["lights"] as? [[String: Any]])

        XCTAssertEqual(object["numberOfLights"] as? Int, 1)
        XCTAssertEqual(lights.count, 1)
        XCTAssertEqual(lights[0]["on"] as? Int, 0)
        XCTAssertNil(lights[0]["brightness"])
        XCTAssertNil(lights[0]["temperature"])
    }

    func testBonjourEndpointBuildsTheElgatoLightsURL() {
        let endpoint = ControlCenterLightEndpoint(
            id: "Elgato Key Light MK 2 B2D7",
            host: "elgato-key-light-mk-2-b2d7.local.",
            port: 9123
        )

        XCTAssertEqual(
            endpoint.lightsURL.absoluteString,
            "http://elgato-key-light-mk-2-b2d7.local.:9123/elgato/lights"
        )
    }

    func testWidgetIsInstalledAndEnabledByDefault() {
        XCTAssertEqual(installedTaskbarWidgetIDs(), [.stats, .battery, .controlCenterLights, .dateTime])
        XCTAssertTrue(TaskbarSettingValues.defaults.controlCenterLightsWidget.isEnabled)
        XCTAssertEqual(activeTaskbarWidgets(for: .defaults).map(\.id), [.stats, .battery, .controlCenterLights, .dateTime])
    }

    func testMissingSettingsMigrateToEnabledDefaults() throws {
        let encoded = try JSONEncoder().encode(TaskbarSettingValues.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "controlCenterLightsWidget")

        let decoded = try JSONDecoder().decode(
            TaskbarSettingValues.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.controlCenterLightsWidget, .defaults)
    }

    func testMonitorOverrideCanHideLightsButtonWithoutChangingGeneralDefault() {
        let settings = TaskbarSettings(store: RecordingControlCenterLightsSettingsStore())
        settings.updateOverrides(for: "display:studio") {
            $0.controlCenterLightsWidget = ControlCenterLightsWidgetSettings(isEnabled: false)
        }

        XCTAssertTrue(settings.preferences.general.controlCenterLightsWidget.isEnabled)
        XCTAssertFalse(settings.values(for: "display:studio").controlCenterLightsWidget.isEnabled)
        XCTAssertTrue(settings.values(for: "display:other").controlCenterLightsWidget.isEnabled)
    }

    func testMonitorWidgetMenuUpdatesItsOverrideInsteadOfTheGeneralDefault() throws {
        let settings = TaskbarSettings(store: RecordingControlCenterLightsSettingsStore())
        settings.updateOverrides(for: "display:studio") {
            $0.controlCenterLightsWidget = ControlCenterLightsWidgetSettings(isEnabled: true)
        }
        let controller = TaskbarController(settings: settings, startAtLoginSync: { _ in })
        let menu = try XCTUnwrap(
            controller.makeWidgetMenu(
                for: .controlCenterLights,
                screenID: 7,
                monitorID: "display:studio"
            )
        )
        let showItem = try XCTUnwrap(menu.items.first { $0.title == "Show Lights Button" })

        _ = controller.perform(try XCTUnwrap(showItem.action), with: showItem)

        XCTAssertTrue(settings.preferences.general.controlCenterLightsWidget.isEnabled)
        XCTAssertFalse(settings.preferences.monitorOverrides["display:studio"]?.controlCenterLightsWidget?.isEnabled ?? true)
    }
}

private final class RecordingControlCenterLightsSettingsStore: TaskbarSettingsStoring {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data, forKey key: String) {}
}
