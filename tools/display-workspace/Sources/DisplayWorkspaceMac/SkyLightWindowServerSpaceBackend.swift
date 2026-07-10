import CoreGraphics
import Darwin
import Foundation

public enum SkyLightSpaceError: Error, LocalizedError {
    case frameworkUnavailable(String)
    case symbolUnavailable(String)
    case invalidManagedSpaces
    case moveFailed(step: String, status: Int32)
    case moveVerificationFailed(
        expected: UInt64,
        actual: UInt64?,
        assignStatus: Int32,
        moveStatus: Int32
    )

    public var errorDescription: String? {
        switch self {
        case let .frameworkUnavailable(path):
            return "Could not load WindowServer framework at \(path)."
        case let .symbolUnavailable(symbol):
            return "WindowServer symbol \(symbol) is unavailable on this macOS version."
        case .invalidManagedSpaces:
            return "WindowServer returned an invalid Desktop list."
        case let .moveFailed(step, status):
            return "Could not move a window to its Desktop during \(step) (status \(status))."
        case let .moveVerificationFailed(expected, actual, assignStatus, moveStatus):
            return "WindowServer did not move the window to Desktop \(expected) "
                + "(actual \(actual.map(String.init) ?? "unknown"), statuses \(assignStatus)/\(moveStatus))."
        }
    }
}

public final class SkyLightWindowServerSpaceBackend: WindowServerSpaceBackend {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (
        Int32,
        Int32,
        CFArray
    ) -> Unmanaged<CFArray>?
    private typealias SpaceSetCompatID = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SetWindowListWorkspace = @convention(c) (
        Int32,
        UnsafeMutablePointer<UInt32>,
        Int32,
        Int32
    ) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let connection: Int32
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
    private let copySpacesForWindows: CopySpacesForWindows
    private let spaceSetCompatID: SpaceSetCompatID
    private let setWindowListWorkspace: SetWindowListWorkspace

    public init() throws {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW) else {
            throw SkyLightSpaceError.frameworkUnavailable(path)
        }
        self.handle = handle

        let mainConnection: MainConnection = try Self.load(
            symbol: "SLSMainConnectionID",
            from: handle
        )
        copyManagedDisplaySpaces = try Self.load(
            symbol: "SLSCopyManagedDisplaySpaces",
            from: handle
        )
        copySpacesForWindows = try Self.load(
            symbol: "SLSCopySpacesForWindows",
            from: handle
        )
        spaceSetCompatID = try Self.load(
            symbol: "SLSSpaceSetCompatID",
            from: handle
        )
        setWindowListWorkspace = try Self.load(
            symbol: "SLSSetWindowListWorkspace",
            from: handle
        )
        connection = mainConnection()
    }

    public func managedDisplaySpaces() throws -> [WindowServerDisplaySpaces] {
        guard let unmanaged = copyManagedDisplaySpaces(connection) else {
            throw SkyLightSpaceError.invalidManagedSpaces
        }
        let rawDisplays = unmanaged.takeRetainedValue() as NSArray
        var displays: [WindowServerDisplaySpaces] = []

        for case let display as NSDictionary in rawDisplays {
            guard let identifier = display["Display Identifier"] as? String,
                  let rawSpaces = display["Spaces"] as? NSArray else { continue }
            var spaces: [WindowServerSpace] = []
            for case let rawSpace as NSDictionary in rawSpaces {
                guard let id = rawSpace["id64"] as? NSNumber,
                      let type = rawSpace["type"] as? NSNumber else { continue }
                spaces.append(.init(id: id.uint64Value, type: type.intValue))
            }
            displays.append(.init(displayIdentifier: identifier, spaces: spaces))
        }

        return displays
    }

    public func spaceID(forWindowServerID windowID: UInt32) throws -> UInt64? {
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        guard let unmanaged = copySpacesForWindows(connection, 0x7, windowIDs) else {
            return nil
        }
        let spaces = unmanaged.takeRetainedValue() as NSArray
        return (spaces.firstObject as? NSNumber)?.uint64Value
    }

    public func moveWindow(windowServerID: UInt32, toSpaceID: UInt64) throws {
        // Current macOS blocks the old direct move call. This compatibility-ID path is
        // the non-privileged fallback used by yabai when its scripting addition is absent.
        let temporaryWorkspace: Int32 = 0x7961_6265
        let assignStatus = spaceSetCompatID(connection, toSpaceID, temporaryWorkspace)
        defer { _ = spaceSetCompatID(connection, toSpaceID, 0) }

        var windowID = windowServerID
        let moveStatus = setWindowListWorkspace(
            connection,
            &windowID,
            1,
            temporaryWorkspace
        )

        var actualSpaceID: UInt64?
        for _ in 0..<10 {
            actualSpaceID = try spaceID(forWindowServerID: windowServerID)
            if actualSpaceID == toSpaceID {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SkyLightSpaceError.moveVerificationFailed(
            expected: toSpaceID,
            actual: actualSpaceID,
            assignStatus: assignStatus,
            moveStatus: moveStatus
        )
    }

    private static func load<T>(
        symbol: String,
        from handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let pointer = dlsym(handle, symbol) else {
            throw SkyLightSpaceError.symbolUnavailable(symbol)
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}
