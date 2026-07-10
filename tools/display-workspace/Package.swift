// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "display-workspace",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DisplayWorkspaceCore", targets: ["DisplayWorkspaceCore"]),
        .library(name: "DisplayWorkspaceMac", targets: ["DisplayWorkspaceMac"]),
        .executable(name: "display-workspace", targets: ["DisplayWorkspaceApp"]),
    ],
    targets: [
        .target(name: "DisplayWorkspaceCore"),
        .target(
            name: "DisplayWorkspaceMac",
            dependencies: ["DisplayWorkspaceCore"]
        ),
        .executableTarget(
            name: "DisplayWorkspaceApp",
            dependencies: ["DisplayWorkspaceCore", "DisplayWorkspaceMac"]
        ),
        .testTarget(
            name: "DisplayWorkspaceCoreTests",
            dependencies: ["DisplayWorkspaceCore"]
        ),
        .testTarget(
            name: "DisplayWorkspaceMacTests",
            dependencies: ["DisplayWorkspaceMac"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
