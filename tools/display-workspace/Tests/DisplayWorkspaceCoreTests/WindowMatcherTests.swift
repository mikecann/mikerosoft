import Testing
@testable import DisplayWorkspaceCore

@Test("windows from the same app are matched by document before enumeration order")
func windowsMatchByDocumentBeforeOrder() {
    let saved = [
        window(title: "Code", document: "file:///projects/code"),
        window(title: "Notes", document: "file:///projects/notes"),
    ]
    let current = [
        CurrentWindow(
            runtimeID: 40,
            bundleIdentifier: "com.example.editor",
            title: "Notes - edited",
            documentURL: "file:///projects/notes"
        ),
        CurrentWindow(
            runtimeID: 90,
            bundleIdentifier: "com.example.editor",
            title: "Code - edited",
            documentURL: "file:///projects/code"
        ),
    ]

    let matches = WindowMatcher().match(saved: saved, current: current)

    #expect(matches == [
        .init(savedIndex: 0, runtimeID: 90),
        .init(savedIndex: 1, runtimeID: 40),
    ])
}

private func window(title: String, document: String?) -> WindowState {
    WindowState(
        bundleIdentifier: "com.example.editor",
        appName: "Editor",
        title: title,
        documentURL: document,
        displayID: "display",
        frameRelativeToDisplay: .init(
            origin: .init(x: 0, y: 0),
            size: .init(width: 800, height: 600)
        ),
        isMinimized: false
    )
}
