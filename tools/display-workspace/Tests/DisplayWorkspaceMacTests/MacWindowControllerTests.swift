import Testing
@testable import DisplayWorkspaceMac

@Test("captured windows are stored relative to their display")
func capturedWindowsAreRelativeToDisplay() throws {
    let windowSystem = StubWindowSystem(windows: [
        .init(
            runtimeID: 10,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "Codex",
            documentURL: "https://example.com",
            frame: frame(x: 1600, y: 0, width: 800, height: 600),
            isMinimized: false
        ),
    ])
    let displays = StubDisplayGeometryProvider(displays: [
        .init(
            persistentID: "betterdisplay:2",
            frame: frame(x: 0, y: 0, width: 1512, height: 982)
        ),
        .init(
            persistentID: "betterdisplay:7",
            frame: frame(x: 1512, y: -200, width: 2560, height: 1440)
        ),
    ])
    let controller = MacWindowController(windowSystem: windowSystem, displays: displays)

    let layout = try controller.captureWindowLayout()

    #expect(layout.windows == [
        .init(
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "Codex",
            documentURL: "https://example.com",
            displayID: "betterdisplay:7",
            frameRelativeToDisplay: frame(x: 88, y: 200, width: 800, height: 600),
            isMinimized: false
        ),
    ])
}

@Test("restored windows follow their saved display when its global origin changes")
func restoredWindowsFollowDisplayOrigin() throws {
    let windowSystem = RecordingWindowSystem(windows: [
        .init(
            runtimeID: 22,
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            title: "Other",
            documentURL: "file:///other",
            frame: frame(x: 0, y: 0, width: 500, height: 500),
            isMinimized: false
        ),
        .init(
            runtimeID: 33,
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            title: "Project changed title",
            documentURL: "file:///project",
            frame: frame(x: 0, y: 0, width: 500, height: 500),
            isMinimized: false
        ),
    ])
    let displays = StubDisplayGeometryProvider(displays: [
        .init(
            persistentID: "betterdisplay:7",
            frame: frame(x: -2560, y: 100, width: 2560, height: 1440)
        ),
    ])
    let controller = MacWindowController(windowSystem: windowSystem, displays: displays)
    let saved = WindowLayout(windows: [
        .init(
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            title: "Project",
            documentURL: "file:///project",
            displayID: "betterdisplay:7",
            frameRelativeToDisplay: frame(x: 88, y: 200, width: 800, height: 600),
            isMinimized: true
        ),
    ])

    try controller.restore(saved)

    #expect(windowSystem.restorations == [
        .init(
            runtimeID: 33,
            frame: frame(x: -2472, y: 300, width: 800, height: 600),
            isMinimized: true
        ),
    ])
}

@Test("captured windows remember their Desktop index on the target display")
func capturedWindowsRememberDesktopIndex() throws {
    let windowSystem = StubWindowSystem(windows: [
        .init(
            runtimeID: 10,
            windowServerID: 501,
            spaceID: 9001,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "Codex",
            documentURL: nil,
            frame: frame(x: 1600, y: 0, width: 800, height: 600),
            isMinimized: false
        ),
    ])
    let displays = StubDisplayGeometryProvider(displays: [
        .init(
            persistentID: "betterdisplay:7",
            frame: frame(x: 1512, y: -200, width: 2560, height: 1440)
        ),
    ])
    let spaces = StubSpaceSystem(spaces: [
        .init(id: 9000, displayID: "betterdisplay:7", desktopIndex: 0),
        .init(id: 9001, displayID: "betterdisplay:7", desktopIndex: 1),
    ])
    let controller = MacWindowController(
        windowSystem: windowSystem,
        displays: displays,
        spaces: spaces
    )

    let layout = try controller.captureWindowLayout()

    #expect(layout.windows.first?.spaceIndex == 1)
}

@Test("restoring a window moves it to the saved Desktop before applying its frame")
func restoringWindowMovesItToSavedDesktop() throws {
    let windowSystem = RecordingWindowSystem(windows: [
        .init(
            runtimeID: 33,
            windowServerID: 501,
            spaceID: 1,
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            title: "Project",
            documentURL: "file:///project",
            frame: frame(x: 0, y: 0, width: 500, height: 500),
            isMinimized: false
        ),
    ])
    let displays = StubDisplayGeometryProvider(displays: [
        .init(
            persistentID: "betterdisplay:7",
            frame: frame(x: 1512, y: -200, width: 2560, height: 1440)
        ),
    ])
    let spaces = RecordingSpaceSystem(spaces: [
        .init(id: 7000, displayID: "betterdisplay:7", desktopIndex: 0),
        .init(id: 7001, displayID: "betterdisplay:7", desktopIndex: 1),
    ])
    let controller = MacWindowController(
        windowSystem: windowSystem,
        displays: displays,
        spaces: spaces
    )
    let saved = WindowLayout(windows: [
        .init(
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            title: "Project",
            documentURL: "file:///project",
            displayID: "betterdisplay:7",
            spaceIndex: 1,
            frameRelativeToDisplay: frame(x: 88, y: 200, width: 800, height: 600),
            isMinimized: false
        ),
    ])

    try controller.restore(saved)

    #expect(spaces.moves == [.init(windowServerID: 501, spaceID: 7001)])
}

@Test("one unmovable window does not stop the remaining workspace restoration")
func unmovableWindowDoesNotStopRestore() throws {
    let windowSystem = PartiallyFailingWindowSystem(windows: [
        managedWindow(runtimeID: 1, document: "file:///one"),
        managedWindow(runtimeID: 2, document: "file:///two"),
    ])
    let displays = StubDisplayGeometryProvider(displays: [
        .init(
            persistentID: "betterdisplay:2",
            frame: frame(x: 0, y: 0, width: 1512, height: 982)
        ),
    ])
    let controller = MacWindowController(windowSystem: windowSystem, displays: displays)
    let layout = WindowLayout(windows: [
        savedWindow(document: "file:///one"),
        savedWindow(document: "file:///two"),
    ])

    try controller.restore(layout)

    #expect(windowSystem.attemptedRuntimeIDs == [1, 2])
}

@Test("a window already on the saved Desktop is not moved through WindowServer")
func windowAlreadyOnDesktopIsNotMoved() throws {
    let windowSystem = RecordingWindowSystem(windows: [
        .init(
            runtimeID: 33,
            windowServerID: 501,
            spaceID: 7001,
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            title: "Project",
            documentURL: "file:///project",
            frame: frame(x: 0, y: 0, width: 500, height: 500),
            isMinimized: false
        ),
    ])
    let displays = StubDisplayGeometryProvider(displays: [
        .init(
            persistentID: "betterdisplay:7",
            frame: frame(x: 1512, y: -200, width: 2560, height: 1440)
        ),
    ])
    let spaces = RecordingSpaceSystem(spaces: [
        .init(id: 7001, displayID: "betterdisplay:7", desktopIndex: 1),
    ])
    let controller = MacWindowController(
        windowSystem: windowSystem,
        displays: displays,
        spaces: spaces
    )
    let saved = WindowLayout(windows: [
        .init(
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            title: "Project",
            documentURL: "file:///project",
            displayID: "betterdisplay:7",
            spaceIndex: 1,
            frameRelativeToDisplay: frame(x: 88, y: 200, width: 800, height: 600),
            isMinimized: false
        ),
    ])

    try controller.restore(saved)

    #expect(spaces.moves.isEmpty)
}

private func frame(x: Double, y: Double, width: Double, height: Double) -> WorkspaceFrame {
    WorkspaceFrame(
        origin: .init(x: x, y: y),
        size: .init(width: width, height: height)
    )
}

private func managedWindow(runtimeID: Int, document: String) -> ManagedWindow {
    ManagedWindow(
        runtimeID: runtimeID,
        bundleIdentifier: "com.example.editor",
        appName: "Editor",
        title: document,
        documentURL: document,
        frame: frame(x: 0, y: 0, width: 500, height: 500),
        isMinimized: false
    )
}

private func savedWindow(document: String) -> WindowState {
    WindowState(
        bundleIdentifier: "com.example.editor",
        appName: "Editor",
        title: document,
        documentURL: document,
        displayID: "betterdisplay:2",
        frameRelativeToDisplay: frame(x: 20, y: 20, width: 500, height: 500),
        isMinimized: false
    )
}

private struct StubWindowSystem: WindowSystem {
    let windows: [ManagedWindow]

    func currentWindows() throws -> [ManagedWindow] {
        windows
    }

    func restoreWindow(runtimeID: Int, frame: WorkspaceFrame, isMinimized: Bool) throws {}
}

private final class RecordingWindowSystem: WindowSystem {
    struct Restoration: Equatable {
        let runtimeID: Int
        let frame: WorkspaceFrame
        let isMinimized: Bool
    }

    let windows: [ManagedWindow]
    private(set) var restorations: [Restoration] = []

    init(windows: [ManagedWindow]) {
        self.windows = windows
    }

    func currentWindows() throws -> [ManagedWindow] {
        windows
    }

    func restoreWindow(runtimeID: Int, frame: WorkspaceFrame, isMinimized: Bool) throws {
        restorations.append(.init(runtimeID: runtimeID, frame: frame, isMinimized: isMinimized))
    }
}

private final class PartiallyFailingWindowSystem: WindowSystem {
    enum ExpectedFailure: Error {
        case unmovable
    }

    let windows: [ManagedWindow]
    private(set) var attemptedRuntimeIDs: [Int] = []

    init(windows: [ManagedWindow]) {
        self.windows = windows
    }

    func currentWindows() throws -> [ManagedWindow] {
        windows
    }

    func restoreWindow(runtimeID: Int, frame: WorkspaceFrame, isMinimized: Bool) throws {
        attemptedRuntimeIDs.append(runtimeID)
        if runtimeID == 1 {
            throw ExpectedFailure.unmovable
        }
    }
}

private struct StubDisplayGeometryProvider: DisplayGeometryProviding {
    let displays: [DisplayGeometry]

    func currentDisplayGeometries() throws -> [DisplayGeometry] {
        displays
    }
}

private final class StubSpaceSystem: SpaceSystem {
    let spaces: [SpaceDescriptor]

    init(spaces: [SpaceDescriptor]) {
        self.spaces = spaces
    }

    func currentSpaces() throws -> [SpaceDescriptor] {
        spaces
    }

    func moveWindow(windowServerID: UInt32, toSpaceID: UInt64) throws {}
}

private final class RecordingSpaceSystem: SpaceSystem {
    struct Move: Equatable {
        let windowServerID: UInt32
        let spaceID: UInt64
    }

    let spaces: [SpaceDescriptor]
    private(set) var moves: [Move] = []

    init(spaces: [SpaceDescriptor]) {
        self.spaces = spaces
    }

    func currentSpaces() throws -> [SpaceDescriptor] {
        spaces
    }

    func moveWindow(windowServerID: UInt32, toSpaceID: UInt64) throws {
        moves.append(.init(windowServerID: windowServerID, spaceID: toSpaceID))
    }
}
