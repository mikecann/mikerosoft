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
        XCTAssertFalse(TaskbarSettingValues.defaults.controlCenterLightsWidget.controlsTeleprompter)
        XCTAssertEqual(activeTaskbarWidgets(for: .defaults).map(\.id), [.stats, .battery, .controlCenterLights, .dateTime])
    }

    func testLegacyLightsSettingsDoNotStartControllingThePrompterWithoutOptIn() throws {
        let data = Data(#"{"isEnabled":true}"#.utf8)

        let decoded = try JSONDecoder().decode(ControlCenterLightsWidgetSettings.self, from: data)

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertFalse(decoded.controlsTeleprompter)
    }

    func testFindsTheSwitchBelongingToTheElgatoPrompterDisplay() {
        let tree = DisplayLinkAccessibilityNode(
            role: "AXApplication",
            children: [
                DisplayLinkAccessibilityNode(
                    role: "AXGroup",
                    children: [
                        DisplayLinkAccessibilityNode(role: "AXStaticText", text: "Studio Display"),
                        DisplayLinkAccessibilityNode(role: "AXCheckBox", boolValue: true)
                    ]
                ),
                DisplayLinkAccessibilityNode(
                    role: "AXGroup",
                    children: [
                        DisplayLinkAccessibilityNode(role: "AXStaticText", text: "Elgato Prom."),
                        DisplayLinkAccessibilityNode(role: "AXCheckBox", boolValue: false)
                    ]
                )
            ]
        )

        XCTAssertEqual(displayLinkTeleprompterSwitchPath(in: tree), [1, 1])
    }

    func testFindsALabelledPrompterSwitchWithoutDependingOnItsRowShape() {
        let tree = DisplayLinkAccessibilityNode(
            role: "AXApplication",
            children: [
                DisplayLinkAccessibilityNode(
                    role: "AXSwitch",
                    text: "Enable Elgato Prompter",
                    boolValue: true
                )
            ]
        )

        XCTAssertEqual(displayLinkTeleprompterSwitchPath(in: tree), [0])
    }

    func testPrompterSwitchUsesItsPressActionOnlyWhenTheStateNeedsToChange() {
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: true, target: false), .press)
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: false, target: true), .press)
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: true, target: true), .none)
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: false, target: false), .none)
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: nil, target: false), .press)
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
        let prompterItem = try XCTUnwrap(menu.items.first { $0.title == "Include Elgato Prompter" })

        _ = controller.perform(try XCTUnwrap(showItem.action), with: showItem)
        _ = controller.perform(try XCTUnwrap(prompterItem.action), with: prompterItem)

        XCTAssertTrue(settings.preferences.general.controlCenterLightsWidget.isEnabled)
        XCTAssertFalse(settings.preferences.monitorOverrides["display:studio"]?.controlCenterLightsWidget?.isEnabled ?? true)
        XCTAssertTrue(settings.preferences.monitorOverrides["display:studio"]?.controlCenterLightsWidget?.controlsTeleprompter ?? false)
    }
}

private final class RecordingControlCenterLightsSettingsStore: TaskbarSettingsStoring {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data, forKey key: String) {}
}
