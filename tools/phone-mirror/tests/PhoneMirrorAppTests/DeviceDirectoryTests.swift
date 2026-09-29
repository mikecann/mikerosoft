import XCTest
@testable import PhoneMirrorApp

final class DeviceDirectoryTests: XCTestCase {
    private let listing = """
    {"result": {"devices": [
      {"deviceProperties": {"name": "Lets Build It L2"},
       "hardwareProperties": {"udid": "C9C04178", "reality": "simulated"},
       "connectionProperties": {"transportType": "sameMachine"}},
      {"deviceProperties": {"name": "MikeC"},
       "hardwareProperties": {"udid": "00008101-001254300E13A01E", "reality": "physical"},
       "connectionProperties": {"transportType": "localNetwork"}},
      {"deviceProperties": {"name": "MikeXS Max"},
       "hardwareProperties": {"udid": "00008020-000369202E90003A", "reality": "physical"},
       "connectionProperties": {"transportType": "wired", "tunnelIPAddress": "fde5:3a75:9ac2::1"}}
    ]}}
    """.data(using: .utf8)!

    func testReadsPhysicalDevicesOnly() {
        XCTAssertEqual(DeviceDirectory.parse(listing), [
            PhoneDeviceInfo(name: "MikeC", udid: "00008101-001254300E13A01E", tunnelAddress: nil),
            PhoneDeviceInfo(name: "MikeXS Max", udid: "00008020-000369202E90003A", tunnelAddress: "fde5:3a75:9ac2::1"),
        ])
    }

    func testMatchesByNameIgnoringCase() {
        let devices = DeviceDirectory.parse(listing)
        XCTAssertEqual(DeviceDirectory.match(name: "mikexs max", in: devices)?.udid, "00008020-000369202E90003A")
        XCTAssertNil(DeviceDirectory.match(name: "Someone Else", in: devices))
    }

    func testPrefersTheConnectedPhoneWhenNamesClash() {
        let devices = [
            PhoneDeviceInfo(name: "iPhone", udid: "old", tunnelAddress: nil),
            PhoneDeviceInfo(name: "iPhone", udid: "plugged-in", tunnelAddress: "fd00::1"),
        ]
        XCTAssertEqual(DeviceDirectory.match(name: "iPhone", in: devices)?.udid, "plugged-in")
    }

    func testIgnoresMalformedOutput() {
        XCTAssertEqual(DeviceDirectory.parse(Data("not json".utf8)), [])
    }
}
