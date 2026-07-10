import Foundation
import CoreGraphics
import OSLog
@_exported import DisplayWorkspaceCore

private let displayWorkspaceMacLogger = Logger(
    subsystem: "com.mikerosoft.display-workspace",
    category: "mac-adapters"
)

public protocol CommandRunning {
    @discardableResult
    func run(executableURL: URL, arguments: [String]) throws -> String
}

public enum CommandRunnerError: Error, LocalizedError {
    case failed(executable: String, status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .failed(executable, status, message):
            return "\(executable) exited with status \(status): \(message)"
        }
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executableURL: URL, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(decoding: outputData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandRunnerError.failed(
                executable: executableURL.path,
                status: process.terminationStatus,
                message: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public protocol ActiveDisplayProviding {
    func activeDisplayIDs() throws -> [UInt32]
}

public enum ActiveDisplayError: Error {
    case coreGraphics(CGError)
}

public struct CoreGraphicsActiveDisplayProvider: ActiveDisplayProviding {
    public init() {}

    public func activeDisplayIDs() throws -> [UInt32] {
        var count: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &count)
        guard countResult == .success else {
            throw ActiveDisplayError.coreGraphics(countResult)
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listResult = CGGetActiveDisplayList(count, &displays, &count)
        guard listResult == .success else {
            throw ActiveDisplayError.coreGraphics(listResult)
        }
        return Array(displays.prefix(Int(count)))
    }
}

public protocol DisplayBoundsProviding {
    func bounds(for displayID: UInt32) -> WorkspaceFrame
}

public struct CoreGraphicsDisplayBoundsProvider: DisplayBoundsProviding {
    public init() {}

    public func bounds(for displayID: UInt32) -> WorkspaceFrame {
        let bounds = CGDisplayBounds(displayID)
        return WorkspaceFrame(
            origin: WorkspacePoint(x: bounds.origin.x, y: bounds.origin.y),
            size: WorkspaceSize(width: bounds.size.width, height: bounds.size.height)
        )
    }
}

public struct FixedDisplaySettler: DisplaySettling, Sendable {
    public let delay: TimeInterval

    public init(delay: TimeInterval = 2) {
        self.delay = delay
    }

    public func waitForDisplaySystem() throws {
        Thread.sleep(forTimeInterval: delay)
    }
}

public enum BetterDisplayError: Error, LocalizedError {
    case invalidPersistentID(String)
    case invalidIdentifierOutput(String)
    case invalidFeatureValue(feature: String, value: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPersistentID(id):
            return "Not a BetterDisplay persistent ID: \(id)"
        case let .invalidIdentifierOutput(output):
            return "Could not decode BetterDisplay identifiers: \(output)"
        case let .invalidFeatureValue(feature, value):
            return "BetterDisplay returned an invalid \(feature) value: \(value)"
        }
    }
}

private struct BetterDisplayIdentifier: Decodable {
    let uuid: String?
    let deviceType: String
    let displayID: String?
    let name: String
    let tagID: String

    private enum CodingKeys: String, CodingKey {
        case uuid = "UUID"
        case deviceType
        case displayID
        case name
        case tagID
    }
}

public struct DisplayIdentityMap: Equatable, Sendable {
    public let mainDisplayID: String?
    public let uuidToDisplayID: [String: String]

    public init(mainDisplayID: String?, uuidToDisplayID: [String: String]) {
        self.mainDisplayID = mainDisplayID
        self.uuidToDisplayID = uuidToDisplayID
    }
}

public protocol DisplayIdentityMappingProviding {
    func currentDisplayIdentityMap() throws -> DisplayIdentityMap
}

public final class BetterDisplayController:
    DisplayConfigurationCapturing,
    DisplayConfigurationRestoring,
    DisplayGeometryProviding,
    DisplayIdentityMappingProviding
{
    private let executableURL: URL
    private let runner: any CommandRunning
    private let activeDisplays: any ActiveDisplayProviding
    private let displayBounds: any DisplayBoundsProviding

    public init(
        executableURL: URL,
        runner: any CommandRunning = ProcessCommandRunner(),
        activeDisplays: any ActiveDisplayProviding = CoreGraphicsActiveDisplayProvider(),
        displayBounds: any DisplayBoundsProviding = CoreGraphicsDisplayBoundsProvider()
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.activeDisplays = activeDisplays
        self.displayBounds = displayBounds
    }

    public func connectedDisplayIDs() throws -> [String] {
        try activeIdentifiers()
            .map { "betterdisplay:\($0.tagID)" }
    }

    public func captureConfiguration() throws -> DisplayConfiguration {
        let displays = try activeIdentifiers().map { identifier in
            let placement = try parsePoint(
                query(tagID: identifier.tagID, feature: "placement"),
                feature: "placement"
            )
            let resolution = try parseResolution(
                query(tagID: identifier.tagID, feature: "resolution")
            )
            let refreshRate = Double(try query(tagID: identifier.tagID, feature: "refreshRate"))
            let rotationValue = try query(tagID: identifier.tagID, feature: "rotation")
            guard let rotation = Int(rotationValue) else {
                throw BetterDisplayError.invalidFeatureValue(
                    feature: "rotation",
                    value: rotationValue
                )
            }
            let isHiDPI = parseBool(try query(tagID: identifier.tagID, feature: "hiDPI"))
            let isMain = parseBool(try query(tagID: identifier.tagID, feature: "main"))
            return DisplayState(
                persistentID: "betterdisplay:\(identifier.tagID)",
                name: identifier.name,
                origin: placement,
                resolution: resolution,
                refreshRate: refreshRate,
                rotation: rotation,
                isHiDPI: isHiDPI,
                isMain: isMain
            )
        }
        return DisplayConfiguration(displays: displays)
    }

    public func currentDisplayGeometries() throws -> [DisplayGeometry] {
        try activeIdentifiers().compactMap { identifier in
            guard let rawDisplayID = identifier.displayID,
                  let displayID = UInt32(rawDisplayID) else { return nil }
            return DisplayGeometry(
                persistentID: "betterdisplay:\(identifier.tagID)",
                frame: displayBounds.bounds(for: displayID)
            )
        }
    }

    public func currentDisplayIdentityMap() throws -> DisplayIdentityMap {
        let active = try activeIdentifiers()
        var mainDisplayID: String?
        var uuidToDisplayID: [String: String] = [:]
        for identifier in active {
            let persistentID = "betterdisplay:\(identifier.tagID)"
            if let uuid = identifier.uuid {
                uuidToDisplayID[uuid] = persistentID
            }
            if parseBool(try query(tagID: identifier.tagID, feature: "main")) {
                mainDisplayID = persistentID
            }
        }
        return DisplayIdentityMap(
            mainDisplayID: mainDisplayID,
            uuidToDisplayID: uuidToDisplayID
        )
    }

    public func restore(_ configuration: DisplayConfiguration) throws {
        let displays = configuration.displays.sorted {
            $0.isMain && !$1.isMain
        }

        for display in displays {
            var arguments = [
                "set",
                "-tagID=\(try tagID(from: display.persistentID))",
                "-resolution=\(display.resolution.width)x\(display.resolution.height)",
                "-hiDPI=\(display.isHiDPI ? "on" : "off")",
            ]
            if let refreshRate = display.refreshRate {
                arguments.append("-refreshRate=\(format(refreshRate))")
            }
            arguments.append("-rotation=\(display.rotation)")
            if display.isMain {
                arguments.append("-main=on")
            }
            try runner.run(executableURL: executableURL, arguments: arguments)
        }

        for display in displays {
            try runner.run(
                executableURL: executableURL,
                arguments: [
                    "set",
                    "-tagID=\(try tagID(from: display.persistentID))",
                    "-placement=\(format(display.origin.x))x\(format(display.origin.y))",
                ]
            )
        }
    }

    private func tagID(from persistentID: String) throws -> String {
        let prefix = "betterdisplay:"
        guard persistentID.hasPrefix(prefix) else {
            throw BetterDisplayError.invalidPersistentID(persistentID)
        }
        return String(persistentID.dropFirst(prefix.count))
    }

    private func identifiers() throws -> [BetterDisplayIdentifier] {
        let output = try runner.run(
            executableURL: executableURL,
            arguments: ["get", "-identifiers"]
        )
        guard let data = "[\(output)]".data(using: .utf8) else {
            throw BetterDisplayError.invalidIdentifierOutput(output)
        }
        do {
            return try JSONDecoder().decode([BetterDisplayIdentifier].self, from: data)
        } catch {
            throw BetterDisplayError.invalidIdentifierOutput(output)
        }
    }

    private func activeIdentifiers() throws -> [BetterDisplayIdentifier] {
        let activeIDs = Set(try activeDisplays.activeDisplayIDs().map(String.init))
        return try identifiers()
            .filter { identifier in
                guard identifier.deviceType != "DisplayGroup",
                      let displayID = identifier.displayID else { return false }
                return activeIDs.contains(displayID)
            }
            .sorted { (Int($0.tagID) ?? 0) < (Int($1.tagID) ?? 0) }
    }

    private func query(tagID: String, feature: String) throws -> String {
        try runner.run(
            executableURL: executableURL,
            arguments: ["get", "-tagID=\(tagID)", "-\(feature)"]
        )
    }

    private func parsePoint(_ value: String, feature: String) throws -> WorkspacePoint {
        let parts = value.split(separator: "x", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            throw BetterDisplayError.invalidFeatureValue(feature: feature, value: value)
        }
        return WorkspacePoint(x: x, y: y)
    }

    private func parseResolution(_ value: String) throws -> DisplayResolution {
        let point = try parsePoint(value, feature: "resolution")
        return DisplayResolution(width: Int(point.x), height: Int(point.y))
    }

    private func parseBool(_ value: String) -> Bool {
        ["1", "on", "true", "yes"].contains(value.lowercased())
    }

    private func format(_ number: Double) -> String {
        if number.rounded() == number {
            return String(Int(number))
        }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), number)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

public struct ManagedWindow: Equatable, Sendable {
    public let runtimeID: Int
    public let windowServerID: UInt32?
    public let spaceID: UInt64?
    public let bundleIdentifier: String
    public let appName: String
    public let title: String?
    public let documentURL: String?
    public let frame: WorkspaceFrame
    public let isMinimized: Bool

    public init(
        runtimeID: Int,
        windowServerID: UInt32? = nil,
        spaceID: UInt64? = nil,
        bundleIdentifier: String,
        appName: String,
        title: String?,
        documentURL: String?,
        frame: WorkspaceFrame,
        isMinimized: Bool
    ) {
        self.runtimeID = runtimeID
        self.windowServerID = windowServerID
        self.spaceID = spaceID
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.documentURL = documentURL
        self.frame = frame
        self.isMinimized = isMinimized
    }
}

public protocol WindowSystem {
    func currentWindows() throws -> [ManagedWindow]
    func restoreWindow(runtimeID: Int, frame: WorkspaceFrame, isMinimized: Bool) throws
}

public struct DisplayGeometry: Equatable, Sendable {
    public let persistentID: String
    public let frame: WorkspaceFrame

    public init(persistentID: String, frame: WorkspaceFrame) {
        self.persistentID = persistentID
        self.frame = frame
    }
}

public protocol DisplayGeometryProviding {
    func currentDisplayGeometries() throws -> [DisplayGeometry]
}

public struct SpaceDescriptor: Equatable, Sendable {
    public let id: UInt64
    public let displayID: String
    public let desktopIndex: Int

    public init(id: UInt64, displayID: String, desktopIndex: Int) {
        self.id = id
        self.displayID = displayID
        self.desktopIndex = desktopIndex
    }
}

public protocol SpaceSystem {
    func currentSpaces() throws -> [SpaceDescriptor]
    func moveWindow(windowServerID: UInt32, toSpaceID: UInt64) throws
}

public struct NoopSpaceSystem: SpaceSystem, Sendable {
    public init() {}

    public func currentSpaces() throws -> [SpaceDescriptor] { [] }
    public func moveWindow(windowServerID: UInt32, toSpaceID: UInt64) throws {}
}

public final class MacWindowController: WindowLayoutCapturing, WindowLayoutRestoring {
    private let windowSystem: any WindowSystem
    private let displays: any DisplayGeometryProviding
    private let spaces: any SpaceSystem

    public init(
        windowSystem: any WindowSystem,
        displays: any DisplayGeometryProviding,
        spaces: any SpaceSystem = NoopSpaceSystem()
    ) {
        self.windowSystem = windowSystem
        self.displays = displays
        self.spaces = spaces
    }

    public func captureWindowLayout() throws -> WindowLayout {
        let displayGeometries = try displays.currentDisplayGeometries()
        let currentSpaces = try spaces.currentSpaces()
        let windows = try windowSystem.currentWindows().compactMap { window -> WindowState? in
            let savedSpace = window.spaceID.flatMap { spaceID in
                currentSpaces.first { $0.id == spaceID }
            }
            let spaceDisplay = savedSpace.flatMap { savedSpace in
                displayGeometries.first { $0.persistentID == savedSpace.displayID }
            }
            guard let display = spaceDisplay ?? displayGeometries.max(by: {
                intersectionArea(window.frame, $0.frame) < intersectionArea(window.frame, $1.frame)
            }) else { return nil }
            return WindowState(
                bundleIdentifier: window.bundleIdentifier,
                appName: window.appName,
                title: window.title,
                documentURL: window.documentURL,
                displayID: display.persistentID,
                spaceIndex: savedSpace?.desktopIndex,
                frameRelativeToDisplay: WorkspaceFrame(
                    origin: WorkspacePoint(
                        x: window.frame.origin.x - display.frame.origin.x,
                        y: window.frame.origin.y - display.frame.origin.y
                    ),
                    size: window.frame.size
                ),
                isMinimized: window.isMinimized
            )
        }
        return WindowLayout(windows: windows)
    }

    public func restore(_ layout: WindowLayout) throws {
        let currentWindows = try windowSystem.currentWindows()
        let displayGeometries = try displays.currentDisplayGeometries()
        let currentSpaces = try spaces.currentSpaces()
        let matches = WindowMatcher().match(
            saved: layout.windows,
            current: currentWindows.map {
                CurrentWindow(
                    runtimeID: $0.runtimeID,
                    bundleIdentifier: $0.bundleIdentifier,
                    title: $0.title,
                    documentURL: $0.documentURL
                )
            }
        )

        for match in matches {
            let saved = layout.windows[match.savedIndex]
            if let spaceIndex = saved.spaceIndex,
               let currentWindow = currentWindows.first(where: {
                   $0.runtimeID == match.runtimeID
               }),
               let windowServerID = currentWindow.windowServerID,
               let targetSpace = currentSpaces.first(where: {
                   $0.displayID == saved.displayID && $0.desktopIndex == spaceIndex
               }),
               currentWindow.spaceID != targetSpace.id {
                do {
                    try spaces.moveWindow(
                        windowServerID: windowServerID,
                        toSpaceID: targetSpace.id
                    )
                } catch {
                    displayWorkspaceMacLogger.error(
                        "Could not restore Desktop for \(saved.appName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            guard let display = displayGeometries.first(where: {
                $0.persistentID == saved.displayID
            }) else { continue }
            let frame = WorkspaceFrame(
                origin: WorkspacePoint(
                    x: display.frame.origin.x + saved.frameRelativeToDisplay.origin.x,
                    y: display.frame.origin.y + saved.frameRelativeToDisplay.origin.y
                ),
                size: saved.frameRelativeToDisplay.size
            )
            do {
                try windowSystem.restoreWindow(
                    runtimeID: match.runtimeID,
                    frame: frame,
                    isMinimized: saved.isMinimized
                )
            } catch {
                displayWorkspaceMacLogger.error(
                    "Could not restore \(saved.appName, privacy: .public) window: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func intersectionArea(_ lhs: WorkspaceFrame, _ rhs: WorkspaceFrame) -> Double {
        let left = max(lhs.origin.x, rhs.origin.x)
        let top = max(lhs.origin.y, rhs.origin.y)
        let right = min(
            lhs.origin.x + lhs.size.width,
            rhs.origin.x + rhs.size.width
        )
        let bottom = min(
            lhs.origin.y + lhs.size.height,
            rhs.origin.y + rhs.size.height
        )
        return max(0, right - left) * max(0, bottom - top)
    }
}
