import Foundation

/// A physical phone as Xcode sees it.
struct PhoneDeviceInfo: Equatable {
    let name: String
    let udid: String
    /// Address of the USB tunnel Xcode keeps open to the phone, once it's connected.
    let tunnelAddress: String?
}

/// Looks phones up through `xcrun devicectl`, matching the name the phone's screen reports.
enum DeviceDirectory {
    static func lookup(name: String) async -> PhoneDeviceInfo? {
        await Task.detached {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("phone-mirror-devices-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: output) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["devicectl", "list", "devices", "--json-output", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let data = try Data(contentsOf: output)
                return match(name: name, in: parse(data))
            } catch {
                Log.info("devicectl failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    static func parse(_ data: Data) -> [PhoneDeviceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String == "physical",
                  let name = (device["deviceProperties"] as? [String: Any])?["name"] as? String,
                  let udid = hardware["udid"] as? String else { return nil }
            return PhoneDeviceInfo(name: name, udid: udid, tunnelAddress: connection["tunnelIPAddress"] as? String)
        }
    }

    /// Prefers the phone with a live USB tunnel when two share a name.
    static func match(name: String, in devices: [PhoneDeviceInfo]) -> PhoneDeviceInfo? {
        let named = devices.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return named.first { $0.tunnelAddress != nil } ?? named.first
    }
}
