import Foundation
import DisplayWorkspaceCore

public struct WindowServerSpace: Equatable, Sendable {
    public let id: UInt64
    public let type: Int

    public init(id: UInt64, type: Int) {
        self.id = id
        self.type = type
    }
}

public struct WindowServerDisplaySpaces: Equatable, Sendable {
    public let displayIdentifier: String
    public let spaces: [WindowServerSpace]

    public init(displayIdentifier: String, spaces: [WindowServerSpace]) {
        self.displayIdentifier = displayIdentifier
        self.spaces = spaces
    }
}

public protocol WindowServerSpaceBackend {
    func managedDisplaySpaces() throws -> [WindowServerDisplaySpaces]
    func spaceID(forWindowServerID windowID: UInt32) throws -> UInt64?
    func moveWindow(windowServerID: UInt32, toSpaceID: UInt64) throws
}

public protocol WindowSpaceLocating {
    func spaceID(forWindowServerID windowID: UInt32) throws -> UInt64?
}

public final class MacSpaceSystem: SpaceSystem, WindowSpaceLocating {
    private let backend: any WindowServerSpaceBackend
    private let identities: any DisplayIdentityMappingProviding

    public init(
        backend: any WindowServerSpaceBackend,
        identities: any DisplayIdentityMappingProviding
    ) {
        self.backend = backend
        self.identities = identities
    }

    public func currentSpaces() throws -> [SpaceDescriptor] {
        let identityMap = try identities.currentDisplayIdentityMap()
        return try backend.managedDisplaySpaces().flatMap { displaySpaces -> [SpaceDescriptor] in
            let displayID: String?
            if displaySpaces.displayIdentifier == "Main" {
                displayID = identityMap.mainDisplayID
            } else {
                displayID = identityMap.uuidToDisplayID[displaySpaces.displayIdentifier]
            }
            guard let displayID else { return [] }

            return displaySpaces.spaces
                .filter { $0.type == 0 }
                .enumerated()
                .map { index, space in
                    SpaceDescriptor(id: space.id, displayID: displayID, desktopIndex: index)
                }
        }
    }

    public func spaceID(forWindowServerID windowID: UInt32) throws -> UInt64? {
        try backend.spaceID(forWindowServerID: windowID)
    }

    public func moveWindow(windowServerID: UInt32, toSpaceID: UInt64) throws {
        try backend.moveWindow(windowServerID: windowServerID, toSpaceID: toSpaceID)
    }
}
