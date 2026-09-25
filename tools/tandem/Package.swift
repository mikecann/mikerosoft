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
        .library(name: "TandemAPI", targets: ["TandemAPI"]),
        .library(name: "TandemAssets", targets: ["TandemAssets"])
    ],
    dependencies: [
        // Renders Lottie stickers to video at import (TandemAssets only).
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.6.1")
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
        // Commands shared by the local server, the CLI and MCP, including
        // the asset library for agents.
        .target(name: "TandemAPI", dependencies: ["TandemCore", "TandemMedia", "TandemRender", "TandemAssets"], path: "Sources/TandemAPI"),
        // Importers: Filmora .wfp projects and the JSON EDLs agents cut with.
        // They build through the coordinator, so imports always validate.
        .target(name: "TandemImport", dependencies: ["TandemCore", "TandemMedia"], path: "Sources/TandemImport"),
        // The macOS app. Its keymap and other defaults ship as resources.
        .executableTarget(
            name: "TandemApp",
            dependencies: ["TandemCore", "TandemMedia", "TandemRender", "TandemAPI", "TandemAssets"],
            path: "Sources/TandemApp",
            resources: [.copy("Resources/Keymaps")]
        ),
        .executableTarget(name: "TandemCLI", dependencies: ["TandemCore", "TandemMedia", "TandemRender", "TandemAPI", "TandemImport", "TandemAssets"], path: "Sources/TandemCLI"),
        .testTarget(name: "TandemCoreTests", dependencies: ["TandemCore"], path: "tests/TandemCoreTests"),
        .testTarget(name: "TandemMediaTests", dependencies: ["TandemMedia"], path: "tests/TandemMediaTests"),
        .testTarget(name: "TandemRenderTests", dependencies: ["TandemRender"], path: "tests/TandemRenderTests"),
        // Depends on the CLI so `swift test` builds the `tandem` binary that the
        // end-to-end tests run.
        .testTarget(name: "TandemAPITests", dependencies: ["TandemAPI", "TandemCLI", "TandemAssets"], path: "tests/TandemAPITests"),
        .testTarget(
            name: "TandemImportTests",
            dependencies: ["TandemImport"],
            path: "tests/TandemImportTests",
            resources: [.copy("Fixtures")]
        ),
        // The asset library: catalogue (system SQLite with FTS5), providers,
        // normalising on import and copying assets into projects.
        .target(
            name: "TandemAssets",
            dependencies: ["TandemCore", "TandemMedia", .product(name: "Lottie", package: "lottie-ios")],
            path: "Sources/TandemAssets",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TandemAssetsTests",
            dependencies: ["TandemAssets"],
            path: "tests/TandemAssetsTests",
            resources: [.copy("Fixtures")]
        ),
        // The app's pure logic: timeline maths, snapping, hit testing, the
        // keymap and how gestures become edit batches.
        .testTarget(name: "TandemAppTests", dependencies: ["TandemApp", "TandemCore"], path: "tests/TandemAppTests")
    ],
    swiftLanguageModes: [.v5]
)
