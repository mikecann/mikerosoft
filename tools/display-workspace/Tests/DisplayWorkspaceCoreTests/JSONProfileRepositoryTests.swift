import Foundation
import Testing
@testable import DisplayWorkspaceCore

@Test("saving a profile replaces the previous profile with that name on disk")
func savingProfileReplacesNamedProfileOnDisk() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("profiles.json")
    let repository = JSONProfileRepository(fileURL: fileURL)
    let original = profile(name: "Docked", displayIDs: ["display:old"])
    let updated = profile(name: "Docked", displayIDs: ["display:new"])

    try repository.saveProfile(original)
    try repository.saveProfile(updated)

    let reloaded = try JSONProfileRepository(fileURL: fileURL).loadProfiles()
    #expect(reloaded == [updated])
}

private func profile(name: String, displayIDs: [String]) -> WorkspaceProfile {
    WorkspaceProfile(
        name: name,
        displayIDs: displayIDs,
        displayConfiguration: .init(displays: []),
        windowLayout: .init(windows: [])
    )
}
