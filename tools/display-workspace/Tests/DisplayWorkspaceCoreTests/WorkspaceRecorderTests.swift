import Testing
@testable import DisplayWorkspaceCore

@Test("saving the current setup captures and persists one complete workspace")
func savingCurrentSetupCapturesCompleteWorkspace() throws {
    let profiles = RecordingProfileRepository()
    let recorder = WorkspaceRecorder(
        profiles: profiles,
        displays: StubDisplayCapturer(configuration: .init(displays: [])),
        windows: StubWindowCapturer(layout: .init(windows: []))
    )

    let saved = try recorder.saveCurrentWorkspace(
        name: "Docked",
        connectedDisplayIDs: ["betterdisplay:8", "betterdisplay:2", "betterdisplay:7"]
    )

    #expect(saved.name == "Docked")
    #expect(saved.displayIDs == ["betterdisplay:2", "betterdisplay:7", "betterdisplay:8"])
    #expect(saved.displayConfiguration == .init(displays: []))
    #expect(saved.windowLayout == .init(windows: []))
    #expect(profiles.saved == [saved])
}

private final class RecordingProfileRepository: MutableProfileRepository {
    private(set) var saved: [WorkspaceProfile] = []

    func loadProfiles() throws -> [WorkspaceProfile] {
        saved
    }

    func saveProfile(_ profile: WorkspaceProfile) throws {
        saved.append(profile)
    }
}

private struct StubDisplayCapturer: DisplayConfigurationCapturing {
    let configuration: DisplayConfiguration

    func captureConfiguration() throws -> DisplayConfiguration {
        configuration
    }
}

private struct StubWindowCapturer: WindowLayoutCapturing {
    let layout: WindowLayout

    func captureWindowLayout() throws -> WindowLayout {
        layout
    }
}
