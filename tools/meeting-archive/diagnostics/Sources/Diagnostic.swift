import AVFoundation
import CoreGraphics
import CoreMediaIO
import Foundation
import ScreenCaptureKit

private let schemaVersion = 1

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct CameraObservation: Codable, Equatable {
    let uniqueID: String
    let localizedName: String
    let manufacturer: String
    let modelID: String
    let deviceType: String
    let position: String
    let transportType: UInt32
    let isConnected: Bool
    let isSuspended: Bool
    let isContinuityCamera: Bool
    let avFoundationInUseByAnotherApplication: Bool
    let cmioObjectID: UInt32?
    let cmioDeviceIsRunningSomewhere: Bool?
    let cmioLookupError: String?
}

private struct WindowCandidate: Codable, Equatable {
    let window: WindowObservation
    let assessment: CandidateAssessment
}

private struct EvidenceBoundary: Codable {
    let passiveOnly: Bool
    let cameraSignalScope: String
    let windowSignalScope: String
    let ownershipClaim: String
}

private struct DiagnosticPayload: Codable, Equatable {
    let cameraAuthorization: String?
    let screenRecordingPermission: Bool?
    let cameras: [CameraObservation]?
    let cmioDevices: [CMIODeviceState]?
    let windows: [WindowCandidate]?
    let error: String?
}

private struct DiagnosticEvent: Codable {
    let schemaVersion: Int
    let timestamp: String
    let mode: String
    let event: String
    let evidenceBoundary: EvidenceBoundary
    let payload: DiagnosticPayload
}

private struct CMIODeviceState: Codable, Equatable {
    let objectID: UInt32
    let uid: String?
    let name: String?
    let manufacturer: String?
    let modelUID: String?
    let runningSomewhere: Bool?
    let error: String?
}

private struct CMIOInventory {
    let devices: [CMIODeviceState]
    let error: String?
}

private struct CameraSnapshot {
    let cameras: [CameraObservation]
    let cmioDevices: [CMIODeviceState]
    let error: String?
}

private enum Mode: String {
    case snapshot
    case camera
    case inventory
    case watch
    case help
}

private struct Options {
    var mode: Mode = .snapshot
    var intervalSeconds: Double = 1
    var samples: Int = 60
    var allWindows = false
    var emitUnchanged = false
}

private enum ArgumentError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): message
        }
    }
}

private enum WindowInventoryError: Error, CustomStringConvertible {
    case permissionMissing

    var description: String {
        switch self {
        case .permissionMissing:
            "Screen Recording permission is not currently granted. The diagnostic did not request it or call ScreenCaptureKit."
        }
    }
}

@main
private struct MeetingArchiveDiagnostic {
    static func main() async {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            if options.mode == .help {
                printUsage()
                return
            }

            switch options.mode {
            case .snapshot, .camera, .inventory:
                let payload = await snapshot(options: options)
                emit(mode: options.mode.rawValue, event: "snapshot", payload: payload)
            case .watch:
                await watch(options: options)
            case .help:
                break
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n\n".utf8))
            printUsage(toStandardError: true)
            Foundation.exit(2)
        }
    }

    private static func watch(options: Options) async {
        var previous: DiagnosticPayload?

        for sample in 0..<options.samples {
            if Task.isCancelled { return }

            let payload = await snapshot(options: options)
            let changed = payload != previous
            if sample == 0 || changed || options.emitUnchanged {
                emit(
                    mode: options.mode.rawValue,
                    event: sample == 0 ? "initial" : (changed ? "change" : "unchanged"),
                    payload: payload
                )
            }
            previous = payload

            if sample + 1 < options.samples {
                let nanoseconds = UInt64(options.intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    private static func snapshot(options: Options) async -> DiagnosticPayload {
        let includeCameras = options.mode != .inventory
        let includeWindows = options.mode != .camera

        let cameraAuthorization = includeCameras ? authorizationDescription() : nil
        let cameraSnapshot = includeCameras ? cameraObservations() : nil
        let cameras = cameraSnapshot?.cameras
        let cmioDevices = cameraSnapshot?.cmioDevices

        guard includeWindows else {
            return DiagnosticPayload(
                cameraAuthorization: cameraAuthorization,
                screenRecordingPermission: nil,
                cameras: cameras,
                cmioDevices: cmioDevices,
                windows: nil,
                error: cameraSnapshot?.error
            )
        }

        let screenPermission = CGPreflightScreenCaptureAccess()
        guard screenPermission else {
            return DiagnosticPayload(
                cameraAuthorization: cameraAuthorization,
                screenRecordingPermission: false,
                cameras: cameras,
                cmioDevices: cmioDevices,
                windows: nil,
                error: [cameraSnapshot?.error, WindowInventoryError.permissionMissing.description]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }

        do {
            let windows = try await windowCandidates(includeUnrelated: options.allWindows)
            return DiagnosticPayload(
                cameraAuthorization: cameraAuthorization,
                screenRecordingPermission: true,
                cameras: cameras,
                cmioDevices: cmioDevices,
                windows: windows,
                error: cameraSnapshot?.error
            )
        } catch {
            return DiagnosticPayload(
                cameraAuthorization: cameraAuthorization,
                screenRecordingPermission: true,
                cameras: cameras,
                cmioDevices: cmioDevices,
                windows: nil,
                error: [cameraSnapshot?.error, "ScreenCaptureKit inventory failed: \(error)"]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }
    }

    private static func cameraObservations() -> CameraSnapshot {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera,
            .deskViewCamera,
        ]

        // Preserve order while avoiding duplicate device types should Apple alias one.
        deviceTypes = Array(NSOrderedSet(array: deviceTypes).compactMap { $0 as? AVCaptureDevice.DeviceType })

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let cmioInventory = cmioDeviceStates()
        let cmioByUID = Dictionary(uniqueKeysWithValues: cmioInventory.devices.compactMap { state in
            state.uid.map { ($0, state) }
        })

        let cameras = discovery.devices
            .map { device in
                let cmio = cmioByUID[device.uniqueID]
                return CameraObservation(
                    uniqueID: device.uniqueID,
                    localizedName: device.localizedName,
                    manufacturer: device.manufacturer,
                    modelID: device.modelID,
                    deviceType: device.deviceType.rawValue,
                    position: positionDescription(device.position),
                    transportType: UInt32(bitPattern: device.transportType),
                    isConnected: device.isConnected,
                    isSuspended: device.isSuspended,
                    isContinuityCamera: device.isContinuityCamera,
                    avFoundationInUseByAnotherApplication: device.isInUseByAnotherApplication,
                    cmioObjectID: cmio?.objectID,
                    cmioDeviceIsRunningSomewhere: cmio?.runningSomewhere,
                    cmioLookupError: cmio?.error ?? (cmio == nil ? "No CMIO device with the same UID was found." : nil)
                )
            }
            .sorted { lhs, rhs in
                if lhs.localizedName == rhs.localizedName { return lhs.uniqueID < rhs.uniqueID }
                return lhs.localizedName < rhs.localizedName
            }

        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let avError: String? = authorization == .denied || authorization == .restricted
            ? "AVFoundation camera discovery is unavailable because camera authorization is \(authorizationDescription()). CoreMediaIO observations remain separate and may still be available."
            : nil

        return CameraSnapshot(
            cameras: cameras,
            cmioDevices: cmioInventory.devices,
            error: [avError, cmioInventory.error].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        )
    }

    private static func cmioDeviceStates() -> CMIOInventory {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var byteCount: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        )
        guard sizeStatus == noErr else {
            return CMIOInventory(
                devices: [],
                error: "CoreMediaIO device enumeration size query failed with OSStatus \(sizeStatus)."
            )
        }

        let count = Int(byteCount) / MemoryLayout<CMIOObjectID>.size
        var objectIDs = [CMIOObjectID](repeating: 0, count: count)
        var used = byteCount
        let readStatus = objectIDs.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address,
                0,
                nil,
                byteCount,
                &used,
                buffer.baseAddress
            )
        }
        guard readStatus == noErr else {
            return CMIOInventory(
                devices: [],
                error: "CoreMediaIO device enumeration failed with OSStatus \(readStatus)."
            )
        }

        let devices = objectIDs.map { objectID in
            let uidResult = readCMIOString(
                objectID: objectID,
                selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
            )
            let nameResult = readCMIOString(
                objectID: objectID,
                selector: CMIOObjectPropertySelector(kCMIOObjectPropertyName)
            )
            let manufacturerResult = readCMIOString(
                objectID: objectID,
                selector: CMIOObjectPropertySelector(kCMIOObjectPropertyManufacturer)
            )
            let modelResult = readCMIOString(
                objectID: objectID,
                selector: CMIOObjectPropertySelector(kCMIODevicePropertyModelUID)
            )
            let runningResult = readCMIOUInt32(
                objectID: objectID,
                selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
            )

            let errors = [
                uidResult.error,
                nameResult.error,
                manufacturerResult.error,
                modelResult.error,
                runningResult.error,
            ].compactMap { $0 }
            return CMIODeviceState(
                objectID: objectID,
                uid: uidResult.value,
                name: nameResult.value,
                manufacturer: manufacturerResult.value,
                modelUID: modelResult.value,
                runningSomewhere: runningResult.value.map { $0 != 0 },
                error: errors.isEmpty ? nil : errors.joined(separator: "; ")
            )
        }
        return CMIOInventory(devices: devices, error: nil)
    }

    private static func readCMIOUInt32(
        objectID: CMIOObjectID,
        selector: CMIOObjectPropertySelector
    ) -> (value: UInt32?, error: String?) {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(objectID, &address) else {
            return (nil, "CMIO property \(fourCC(selector)) is unavailable")
        }

        var value: UInt32 = 0
        var used = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            used,
            &used,
            &value
        )
        guard status == noErr else {
            return (nil, "CMIO property \(fourCC(selector)) failed with OSStatus \(status)")
        }
        return (value, nil)
    }

    private static func readCMIOString(
        objectID: CMIOObjectID,
        selector: CMIOObjectPropertySelector
    ) -> (value: String?, error: String?) {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(objectID, &address) else {
            return (nil, "CMIO property \(fourCC(selector)) is unavailable")
        }

        var value: Unmanaged<CFString>?
        var used = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = CMIOObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            used,
            &used,
            &value
        )
        guard status == noErr else {
            return (nil, "CMIO property \(fourCC(selector)) failed with OSStatus \(status)")
        }
        guard let value else { return (nil, "CMIO property \(fourCC(selector)) returned no value") }
        return (value.takeRetainedValue() as String, nil)
    }

    private static func windowCandidates(includeUnrelated: Bool) async throws -> [WindowCandidate] {
        // This retrieves metadata only. It deliberately never creates SCStream or
        // SCScreenshotManager objects and therefore never captures pixels or audio.
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )

        return content.windows.compactMap { window in
            guard let owner = window.owningApplication else { return nil }
            let observation = WindowObservation(
                windowID: window.windowID,
                bundleIdentifier: owner.bundleIdentifier,
                applicationName: owner.applicationName,
                title: window.title,
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen,
                x: Double(window.frame.origin.x),
                y: Double(window.frame.origin.y),
                width: Double(window.frame.size.width),
                height: Double(window.frame.size.height)
            )
            let assessment = MeetingSurfaceRules.assess(observation)
            guard includeUnrelated || assessment.supportedApp != nil else { return nil }
            return WindowCandidate(window: observation, assessment: assessment)
        }.sorted { lhs, rhs in
            if lhs.window.bundleIdentifier == rhs.window.bundleIdentifier {
                return lhs.window.windowID < rhs.window.windowID
            }
            return lhs.window.bundleIdentifier < rhs.window.bundleIdentifier
        }
    }

    private static func authorizationDescription() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: "not-determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    private static func positionDescription(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .unspecified: "unspecified"
        case .front: "front"
        case .back: "back"
        @unknown default: "unknown"
        }
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }

    private static func emit(mode: String, event: String, payload: DiagnosticPayload) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = DiagnosticEvent(
            schemaVersion: schemaVersion,
            timestamp: formatter.string(from: Date()),
            mode: mode,
            event: event,
            evidenceBoundary: EvidenceBoundary(
                passiveOnly: true,
                cameraSignalScope: "Device-level AVFoundation and CoreMediaIO state. No capture session is created.",
                windowSignalScope: "ScreenCaptureKit application/window metadata only. No pixels or audio are captured.",
                ownershipClaim: "None. Camera activity and app/window observations are independent; temporal overlap does not identify the camera owner."
            ),
            payload: payload
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(record)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        } catch {
            FileHandle.standardError.write(Data("failed to encode diagnostic event: \(error)\n".utf8))
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0

        if let first = arguments.first, !first.hasPrefix("-") {
            guard let mode = Mode(rawValue: first) else {
                throw ArgumentError.message("unknown mode '\(first)'")
            }
            options.mode = mode
            index = 1
        }

        while index < arguments.count {
            switch arguments[index] {
            case "--all-windows":
                options.allWindows = true
                index += 1
            case "--emit-unchanged":
                options.emitUnchanged = true
                index += 1
            case "--interval":
                guard index + 1 < arguments.count,
                      let value = Double(arguments[index + 1]),
                      value >= 0.1,
                      value <= 60 else {
                    throw ArgumentError.message("--interval must be between 0.1 and 60 seconds")
                }
                options.intervalSeconds = value
                index += 2
            case "--samples":
                guard index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]),
                      value >= 1,
                      value <= 3_600 else {
                    throw ArgumentError.message("--samples must be between 1 and 3600")
                }
                options.samples = value
                index += 2
            case "--help", "-h":
                options.mode = .help
                index += 1
            default:
                throw ArgumentError.message("unknown option '\(arguments[index])'")
            }
        }

        if options.mode != .watch && (options.emitUnchanged || options.intervalSeconds != 1 || options.samples != 60) {
            throw ArgumentError.message("--interval, --samples, and --emit-unchanged apply only to watch mode")
        }

        return options
    }

    private static func printUsage(toStandardError: Bool = false) {
        let usage = """
        Usage: meeting-archive-diagnostic <mode> [options]

          snapshot                 One camera plus supported-window JSON record (default)
          camera                   One camera-only JSON record; never touches ScreenCaptureKit
          inventory                One supported-window JSON record; never captures pixels/audio
          watch                    Poll and emit the initial state plus JSON change records
          help                     Show this help

        Options:
          --all-windows            Include unrelated app windows in snapshot/inventory/watch
          --interval <seconds>     Watch interval, 0.1...60 (default: 1)
          --samples <count>        Bounded watch polls, 1...3600 (default: 60)
          --emit-unchanged         Emit every watch poll instead of changes only

        The tool never requests camera/screen permission, opens a camera, creates an
        SCStream, captures pixels/audio, or claims which process owns a camera.
        """
        let data = Data((usage + "\n").utf8)
        (toStandardError ? FileHandle.standardError : FileHandle.standardOutput).write(data)
    }
}
