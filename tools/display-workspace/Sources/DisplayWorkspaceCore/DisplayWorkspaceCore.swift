import Foundation

public struct WorkspacePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct WorkspaceSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct WorkspaceFrame: Codable, Equatable, Sendable {
    public let origin: WorkspacePoint
    public let size: WorkspaceSize

    public init(origin: WorkspacePoint, size: WorkspaceSize) {
        self.origin = origin
        self.size = size
    }
}

public struct DisplayResolution: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct DisplayState: Codable, Equatable, Sendable {
    public let persistentID: String
    public let name: String
    public let origin: WorkspacePoint
    public let resolution: DisplayResolution
    public let refreshRate: Double?
    public let rotation: Int
    public let isHiDPI: Bool
    public let isMain: Bool

    public init(
        persistentID: String,
        name: String,
        origin: WorkspacePoint,
        resolution: DisplayResolution,
        refreshRate: Double?,
        rotation: Int,
        isHiDPI: Bool,
        isMain: Bool
    ) {
        self.persistentID = persistentID
        self.name = name
        self.origin = origin
        self.resolution = resolution
        self.refreshRate = refreshRate
        self.rotation = rotation
        self.isHiDPI = isHiDPI
        self.isMain = isMain
    }
}

public struct DisplayConfiguration: Codable, Equatable, Sendable {
    public let displays: [DisplayState]

    public init(displays: [DisplayState]) {
        self.displays = displays
    }
}

public struct WindowState: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let appName: String
    public let title: String?
    public let documentURL: String?
    public let displayID: String
    public let spaceIndex: Int?
    public let frameRelativeToDisplay: WorkspaceFrame
    public let isMinimized: Bool

    public init(
        bundleIdentifier: String,
        appName: String,
        title: String?,
        documentURL: String?,
        displayID: String,
        spaceIndex: Int? = nil,
        frameRelativeToDisplay: WorkspaceFrame,
        isMinimized: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.documentURL = documentURL
        self.displayID = displayID
        self.spaceIndex = spaceIndex
        self.frameRelativeToDisplay = frameRelativeToDisplay
        self.isMinimized = isMinimized
    }
}

public struct WindowLayout: Codable, Equatable, Sendable {
    public let windows: [WindowState]

    public init(windows: [WindowState]) {
        self.windows = windows
    }
}

public struct CurrentWindow: Equatable, Sendable {
    public let runtimeID: Int
    public let bundleIdentifier: String
    public let title: String?
    public let documentURL: String?

    public init(
        runtimeID: Int,
        bundleIdentifier: String,
        title: String?,
        documentURL: String?
    ) {
        self.runtimeID = runtimeID
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.documentURL = documentURL
    }
}

public struct WindowMatch: Equatable, Sendable {
    public let savedIndex: Int
    public let runtimeID: Int

    public init(savedIndex: Int, runtimeID: Int) {
        self.savedIndex = savedIndex
        self.runtimeID = runtimeID
    }
}

public struct WindowMatcher: Sendable {
    public init() {}

    public func match(saved: [WindowState], current: [CurrentWindow]) -> [WindowMatch] {
        var usedRuntimeIDs = Set<Int>()
        var matches: [WindowMatch] = []

        for (savedIndex, savedWindow) in saved.enumerated() {
            let available = current.filter {
                $0.bundleIdentifier == savedWindow.bundleIdentifier
                    && !usedRuntimeIDs.contains($0.runtimeID)
            }
            let matched = exactDocumentMatch(for: savedWindow, in: available)
                ?? exactTitleMatch(for: savedWindow, in: available)
                ?? available.first
            guard let matched else { continue }

            usedRuntimeIDs.insert(matched.runtimeID)
            matches.append(.init(savedIndex: savedIndex, runtimeID: matched.runtimeID))
        }

        return matches
    }

    private func exactDocumentMatch(
        for saved: WindowState,
        in current: [CurrentWindow]
    ) -> CurrentWindow? {
        guard let documentURL = saved.documentURL, !documentURL.isEmpty else { return nil }
        return current.first { $0.documentURL == documentURL }
    }

    private func exactTitleMatch(
        for saved: WindowState,
        in current: [CurrentWindow]
    ) -> CurrentWindow? {
        guard let title = saved.title, !title.isEmpty else { return nil }
        return current.first { $0.title == title }
    }
}

public struct WorkspaceProfile: Codable, Equatable, Sendable {
    public let name: String
    public let displayIDs: [String]
    public let displayConfiguration: DisplayConfiguration
    public let windowLayout: WindowLayout

    public init(
        name: String,
        displayIDs: [String],
        displayConfiguration: DisplayConfiguration,
        windowLayout: WindowLayout
    ) {
        self.name = name
        self.displayIDs = displayIDs
        self.displayConfiguration = displayConfiguration
        self.windowLayout = windowLayout
    }
}

public protocol ProfileRepository {
    func loadProfiles() throws -> [WorkspaceProfile]
}

public protocol MutableProfileRepository: ProfileRepository {
    func saveProfile(_ profile: WorkspaceProfile) throws
}

public protocol DisplayConfigurationCapturing {
    func captureConfiguration() throws -> DisplayConfiguration
}

public protocol WindowLayoutCapturing {
    func captureWindowLayout() throws -> WindowLayout
}

public protocol DisplayConfigurationRestoring {
    func restore(_ configuration: DisplayConfiguration) throws
}

public protocol DisplaySettling {
    func waitForDisplaySystem() throws
}

public struct NoopDisplaySettler: DisplaySettling, Sendable {
    public init() {}

    public func waitForDisplaySystem() throws {}
}

public protocol WindowLayoutRestoring {
    func restore(_ layout: WindowLayout) throws
}

public final class JSONProfileRepository: MutableProfileRepository {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadProfiles() throws -> [WorkspaceProfile] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try JSONDecoder().decode(
            [WorkspaceProfile].self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func saveProfile(_ profile: WorkspaceProfile) throws {
        var profiles = try loadProfiles()
        profiles.removeAll { $0.name == profile.name }
        profiles.append(profile)
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}

public enum RestoreResult: Equatable, Sendable {
    case restored(profileName: String)
    case noMatchingProfile
}

public struct WorkspaceRecorder {
    private let profiles: any MutableProfileRepository
    private let displays: any DisplayConfigurationCapturing
    private let windows: any WindowLayoutCapturing

    public init(
        profiles: any MutableProfileRepository,
        displays: any DisplayConfigurationCapturing,
        windows: any WindowLayoutCapturing
    ) {
        self.profiles = profiles
        self.displays = displays
        self.windows = windows
    }

    public func saveCurrentWorkspace(
        name: String,
        connectedDisplayIDs: [String]
    ) throws -> WorkspaceProfile {
        let profile = WorkspaceProfile(
            name: name,
            displayIDs: connectedDisplayIDs.sorted(),
            displayConfiguration: try displays.captureConfiguration(),
            windowLayout: try windows.captureWindowLayout()
        )
        try profiles.saveProfile(profile)
        return profile
    }
}

public struct WorkspaceRestorer {
    private let profiles: any ProfileRepository
    private let displays: any DisplayConfigurationRestoring
    private let settler: any DisplaySettling
    private let windows: any WindowLayoutRestoring

    public init(
        profiles: any ProfileRepository,
        displays: any DisplayConfigurationRestoring,
        settler: any DisplaySettling = NoopDisplaySettler(),
        windows: any WindowLayoutRestoring
    ) {
        self.profiles = profiles
        self.displays = displays
        self.settler = settler
        self.windows = windows
    }

    public func restore(connectedDisplayIDs: [String]) throws -> RestoreResult {
        let connected = Set(connectedDisplayIDs)
        guard let profile = try profiles.loadProfiles().first(where: {
            Set($0.displayIDs) == connected
        }) else {
            return .noMatchingProfile
        }

        try displays.restore(profile.displayConfiguration)
        try settler.waitForDisplaySystem()
        try windows.restore(profile.windowLayout)
        return .restored(profileName: profile.name)
    }
}
