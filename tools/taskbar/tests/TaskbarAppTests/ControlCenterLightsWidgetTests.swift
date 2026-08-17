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
}
