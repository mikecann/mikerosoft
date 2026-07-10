import Testing
@testable import DisplayWorkspaceMac

@Test("WindowServer Spaces map to stable displays and user Desktop indexes")
func windowServerSpacesMapToStableDisplays() throws {
    let backend = StubWindowServerSpaceBackend(displays: [
        .init(displayIdentifier: "Main", spaces: [
            .init(id: 10, type: 0),
            .init(id: 11, type: 4),
        ]),
        .init(displayIdentifier: "DESK-UUID", spaces: [
            .init(id: 20, type: 0),
            .init(id: 21, type: 0),
        ]),
    ])
    let identities = StubDisplayIdentityProvider(map: .init(
        mainDisplayID: "betterdisplay:2",
        uuidToDisplayID: ["DESK-UUID": "betterdisplay:7"]
    ))
    let system = MacSpaceSystem(backend: backend, identities: identities)

    #expect(try system.currentSpaces() == [
        .init(id: 10, displayID: "betterdisplay:2", desktopIndex: 0),
        .init(id: 20, displayID: "betterdisplay:7", desktopIndex: 0),
        .init(id: 21, displayID: "betterdisplay:7", desktopIndex: 1),
    ])
}

@Test("the local WindowServer backend loads and reads the current Desktops")
func localWindowServerBackendReadsDesktops() throws {
    let backend = try SkyLightWindowServerSpaceBackend()

    #expect(try !backend.managedDisplaySpaces().isEmpty)
}

private struct StubWindowServerSpaceBackend: WindowServerSpaceBackend {
    let displays: [WindowServerDisplaySpaces]

    func managedDisplaySpaces() throws -> [WindowServerDisplaySpaces] {
        displays
    }

    func spaceID(forWindowServerID windowID: UInt32) throws -> UInt64? {
        nil
    }

    func moveWindow(windowServerID: UInt32, toSpaceID: UInt64) throws {}
}

private struct StubDisplayIdentityProvider: DisplayIdentityMappingProviding {
    let map: DisplayIdentityMap

    func currentDisplayIdentityMap() throws -> DisplayIdentityMap {
        map
    }
}
