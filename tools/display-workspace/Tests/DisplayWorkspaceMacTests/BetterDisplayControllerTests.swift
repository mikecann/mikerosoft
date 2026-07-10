import Foundation
import Testing
@testable import DisplayWorkspaceMac

@Test("display restoration targets stable BetterDisplay IDs and places screens after mode changes")
func displayRestorationUsesStableIDsAndPlacesLast() throws {
    let runner = RecordingCommandRunner()
    let controller = BetterDisplayController(
        executableURL: URL(fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"),
        runner: runner
    )
    let external = DisplayState(
        persistentID: "betterdisplay:7",
        name: "Desk Display",
        origin: .init(x: 1512, y: -200),
        resolution: .init(width: 2560, height: 1440),
        refreshRate: 144,
        rotation: 0,
        isHiDPI: false,
        isMain: false
    )
    let builtIn = DisplayState(
        persistentID: "betterdisplay:2",
        name: "Built-in Display",
        origin: .init(x: 0, y: 0),
        resolution: .init(width: 1512, height: 982),
        refreshRate: nil,
        rotation: 0,
        isHiDPI: true,
        isMain: true
    )

    try controller.restore(.init(displays: [external, builtIn]))

    #expect(runner.invocations.map(\.arguments) == [
        ["set", "-tagID=2", "-resolution=1512x982", "-hiDPI=on", "-rotation=0", "-main=on"],
        ["set", "-tagID=7", "-resolution=2560x1440", "-hiDPI=off", "-refreshRate=144", "-rotation=0"],
        ["set", "-tagID=2", "-placement=0x0"],
        ["set", "-tagID=7", "-placement=1512x-200"],
    ])
}

@Test("only active displays form the current BetterDisplay topology")
func onlyActiveDisplaysFormTopology() throws {
    let identifiers = """
    {
      "deviceType": "Display",
      "displayID": "1",
      "name": "Built-in Display",
      "tagID": "2"
    },{
      "deviceType": "VirtualScreen",
      "displayID": "0",
      "name": "Offline Virtual",
      "tagID": "11"
    },{
      "deviceType": "Display",
      "displayID": "9",
      "name": "Desk Display",
      "tagID": "7"
    },{
      "deviceType": "DisplayGroup",
      "name": "Default Group",
      "tagID": "-1001"
    }
    """
    let controller = BetterDisplayController(
        executableURL: URL(fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"),
        runner: StubCommandRunner(output: identifiers),
        activeDisplays: StubActiveDisplayProvider(ids: [9, 1])
    )

    #expect(try controller.connectedDisplayIDs() == ["betterdisplay:2", "betterdisplay:7"])
}

@Test("capturing display state records BetterDisplay mode and placement")
func capturingDisplayStateRecordsModeAndPlacement() throws {
    let identifiers = """
    {
      "deviceType": "Display",
      "displayID": "1",
      "name": "Built-in Display",
      "tagID": "2"
    }
    """
    let runner = StubbedCommandRunner(outputs: [
        "get|-identifiers": identifiers,
        "get|-tagID=2|-placement": "0x0",
        "get|-tagID=2|-resolution": "1512x982",
        "get|-tagID=2|-refreshRate": "ProMotion",
        "get|-tagID=2|-rotation": "0",
        "get|-tagID=2|-hiDPI": "on",
        "get|-tagID=2|-main": "true",
    ])
    let controller = BetterDisplayController(
        executableURL: URL(fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"),
        runner: runner,
        activeDisplays: StubActiveDisplayProvider(ids: [1])
    )

    #expect(try controller.captureConfiguration() == .init(displays: [
        .init(
            persistentID: "betterdisplay:2",
            name: "Built-in Display",
            origin: .init(x: 0, y: 0),
            resolution: .init(width: 1512, height: 982),
            refreshRate: nil,
            rotation: 0,
            isHiDPI: true,
            isMain: true
        ),
    ]))
}

@Test("display geometry uses Core Graphics bounds with stable BetterDisplay IDs")
func displayGeometryUsesStableIDs() throws {
    let identifiers = """
    {
      "deviceType": "Display",
      "displayID": "9",
      "name": "Desk Display",
      "tagID": "7"
    }
    """
    let controller = BetterDisplayController(
        executableURL: URL(fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"),
        runner: StubCommandRunner(output: identifiers),
        activeDisplays: StubActiveDisplayProvider(ids: [9]),
        displayBounds: StubDisplayBoundsProvider(bounds: [
            9: .init(
                origin: .init(x: -2560, y: 100),
                size: .init(width: 2560, height: 1440)
            ),
        ])
    )

    #expect(try controller.currentDisplayGeometries() == [
        .init(
            persistentID: "betterdisplay:7",
            frame: .init(
                origin: .init(x: -2560, y: 100),
                size: .init(width: 2560, height: 1440)
            )
        ),
    ])
}

@Test("display identity mapping resolves WindowServer Main and UUID identifiers")
func displayIdentityMappingResolvesMainAndUUID() throws {
    let identifiers = """
    {
      "UUID": "BUILT-IN-UUID",
      "deviceType": "Display",
      "displayID": "1",
      "name": "Built-in Display",
      "tagID": "2"
    },{
      "UUID": "DESK-UUID",
      "deviceType": "Display",
      "displayID": "9",
      "name": "Desk Display",
      "tagID": "7"
    }
    """
    let runner = StubbedCommandRunner(outputs: [
        "get|-identifiers": identifiers,
        "get|-tagID=2|-main": "true",
        "get|-tagID=7|-main": "false",
    ])
    let controller = BetterDisplayController(
        executableURL: URL(fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"),
        runner: runner,
        activeDisplays: StubActiveDisplayProvider(ids: [1, 9])
    )

    #expect(try controller.currentDisplayIdentityMap() == .init(
        mainDisplayID: "betterdisplay:2",
        uuidToDisplayID: [
            "BUILT-IN-UUID": "betterdisplay:2",
            "DESK-UUID": "betterdisplay:7",
        ]
    ))
}

private final class RecordingCommandRunner: CommandRunning {
    struct Invocation {
        let executableURL: URL
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []

    func run(executableURL: URL, arguments: [String]) throws -> String {
        invocations.append(.init(executableURL: executableURL, arguments: arguments))
        return ""
    }
}

private struct StubCommandRunner: CommandRunning {
    let output: String

    func run(executableURL: URL, arguments: [String]) throws -> String {
        output
    }
}

private struct StubbedCommandRunner: CommandRunning {
    let outputs: [String: String]

    func run(executableURL: URL, arguments: [String]) throws -> String {
        outputs[arguments.joined(separator: "|")] ?? ""
    }
}

private struct StubActiveDisplayProvider: ActiveDisplayProviding {
    let ids: [UInt32]

    func activeDisplayIDs() throws -> [UInt32] {
        ids
    }
}

private struct StubDisplayBoundsProvider: DisplayBoundsProviding {
    let bounds: [UInt32: WorkspaceFrame]

    func bounds(for displayID: UInt32) -> WorkspaceFrame {
        bounds[displayID]!
    }
}
