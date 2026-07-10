import Testing
@testable import DisplayWorkspaceCore

@Test("the connected displays select the exact saved workspace")
func connectedDisplaysSelectExactWorkspace() throws {
    let laptop = WorkspaceProfile(
        name: "Laptop",
        displayIDs: ["betterdisplay:2"],
        displayConfiguration: .init(displays: [displayState(id: "laptop-displays")]),
        windowLayout: .init(windows: [windowState(title: "laptop-windows")])
    )
    let docked = WorkspaceProfile(
        name: "Docked",
        displayIDs: ["betterdisplay:2", "betterdisplay:7", "betterdisplay:8"],
        displayConfiguration: .init(displays: [displayState(id: "docked-displays")]),
        windowLayout: .init(windows: [windowState(title: "docked-windows")])
    )
    let displays = RecordingDisplayRestorer()
    let windows = RecordingWindowRestorer()
    let restorer = WorkspaceRestorer(
        profiles: InMemoryProfileRepository(profiles: [laptop, docked]),
        displays: displays,
        windows: windows
    )

    let result = try restorer.restore(
        connectedDisplayIDs: ["betterdisplay:8", "betterdisplay:2", "betterdisplay:7"]
    )

    #expect(result == .restored(profileName: "Docked"))
    #expect(displays.restored == [.init(displays: [displayState(id: "docked-displays")])])
    #expect(windows.restored == [.init(windows: [windowState(title: "docked-windows")])])
}

@Test("window restoration waits for the display system to settle")
func windowsWaitForDisplaysToSettle() throws {
    let events = EventRecorder()
    let profile = WorkspaceProfile(
        name: "Docked",
        displayIDs: ["betterdisplay:2"],
        displayConfiguration: .init(displays: []),
        windowLayout: .init(windows: [])
    )
    let restorer = WorkspaceRestorer(
        profiles: InMemoryProfileRepository(profiles: [profile]),
        displays: EventDisplayRestorer(events: events),
        settler: EventDisplaySettler(events: events),
        windows: EventWindowRestorer(events: events)
    )

    _ = try restorer.restore(connectedDisplayIDs: ["betterdisplay:2"])

    #expect(events.values == ["displays", "settled", "windows"])
}

private func displayState(id: String) -> DisplayState {
    DisplayState(
        persistentID: id,
        name: id,
        origin: .init(x: 0, y: 0),
        resolution: .init(width: 1920, height: 1080),
        refreshRate: 60,
        rotation: 0,
        isHiDPI: false,
        isMain: true
    )
}

private func windowState(title: String) -> WindowState {
    WindowState(
        bundleIdentifier: "com.example.app",
        appName: "Example",
        title: title,
        documentURL: nil,
        displayID: "display",
        frameRelativeToDisplay: .init(
            origin: .init(x: 0, y: 0),
            size: .init(width: 800, height: 600)
        ),
        isMinimized: false
    )
}

private final class InMemoryProfileRepository: ProfileRepository {
    private let profiles: [WorkspaceProfile]

    init(profiles: [WorkspaceProfile]) {
        self.profiles = profiles
    }

    func loadProfiles() throws -> [WorkspaceProfile] {
        profiles
    }
}

private final class RecordingDisplayRestorer: DisplayConfigurationRestoring {
    private(set) var restored: [DisplayConfiguration] = []

    func restore(_ configuration: DisplayConfiguration) throws {
        restored.append(configuration)
    }
}

private final class RecordingWindowRestorer: WindowLayoutRestoring {
    private(set) var restored: [WindowLayout] = []

    func restore(_ layout: WindowLayout) throws {
        restored.append(layout)
    }
}

private final class EventRecorder {
    var values: [String] = []
}

private struct EventDisplayRestorer: DisplayConfigurationRestoring {
    let events: EventRecorder

    func restore(_ configuration: DisplayConfiguration) throws {
        events.values.append("displays")
    }
}

private struct EventDisplaySettler: DisplaySettling {
    let events: EventRecorder

    func waitForDisplaySystem() throws {
        events.values.append("settled")
    }
}

private struct EventWindowRestorer: WindowLayoutRestoring {
    let events: EventRecorder

    func restore(_ layout: WindowLayout) throws {
        events.values.append("windows")
    }
}
