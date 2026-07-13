// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MikerosoftTaskbar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "taskbar-swift", targets: ["TaskbarApp"])
    ],
    targets: [
        .executableTarget(
            name: "TaskbarApp",
            path: "Sources/TaskbarApp"
        ),
        .testTarget(
            name: "TaskbarAppTests",
            dependencies: ["TaskbarApp"],
            path: "tests/TaskbarAppTests"
        )
    ]
)
