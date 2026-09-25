// swift-tools-version: 6.0
import PackageDescription

// Tandem is split so every client (the app, the CLI and the MCP server) goes
// through the same core. Only TandemApp may import AppKit or SwiftUI.
let package = Package(
    name: "Tandem",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "tandem-app", targets: ["TandemApp"]),
        .executable(name: "tandem", targets: ["TandemCLI"]),
        .library(name: "TandemCore", targets: ["TandemCore"]),
        .library(name: "TandemMedia", targets: ["TandemMedia"]),
        .library(name: "TandemRender", targets: ["TandemRender"]),
        .library(name: "TandemAPI", targets: ["TandemAPI"])
    ],
    targets: [
        // Timeline model, time maths, edit commands, undo, persistence and the
        // project coordinator. Pure Swift plus Foundation, no media frameworks.
        .target(name: "TandemCore", path: "Sources/TandemCore"),
        // Folder scanning, probing, pairing and the background job system
        // (proxies, transcripts, cutout mattes, voice isolation, loudness).
        .target(name: "TandemMedia", dependencies: ["TandemCore"], path: "Sources/TandemMedia"),
        // Composition building, the Core Image compositor, audio mix,
        // frame grabs and export.
        .target(name: "TandemRender", dependencies: ["TandemCore", "TandemMedia"], path: "Sources/TandemRender"),
        // Commands shared by the local server, the CLI and MCP.
        .target(name: "TandemAPI", dependencies: ["TandemCore", "TandemMedia", "TandemRender"], path: "Sources/TandemAPI"),
        .executableTarget(name: "TandemApp", dependencies: ["TandemCore", "TandemMedia", "TandemRender", "TandemAPI"], path: "Sources/TandemApp"),
        .executableTarget(name: "TandemCLI", dependencies: ["TandemCore", "TandemMedia", "TandemRender", "TandemAPI"], path: "Sources/TandemCLI"),
        .testTarget(name: "TandemCoreTests", dependencies: ["TandemCore"], path: "tests/TandemCoreTests"),
        .testTarget(name: "TandemMediaTests", dependencies: ["TandemMedia"], path: "tests/TandemMediaTests"),
        .testTarget(name: "TandemRenderTests", dependencies: ["TandemRender"], path: "tests/TandemRenderTests"),
        // Depends on the CLI so `swift test` builds the `tandem` binary that the
        // end-to-end tests run.
        .testTarget(name: "TandemAPITests", dependencies: ["TandemAPI", "TandemCLI"], path: "tests/TandemAPITests")
    ],
    swiftLanguageModes: [.v5]
)
