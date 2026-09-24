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
    dependencies: [
        .package(path: "../lib/PrompterKit")
    ],
    targets: [
        .executableTarget(
            name: "TaskbarApp",
            dependencies: [
                .product(name: "PrompterKit", package: "PrompterKit")
            ],
            path: "Sources/TaskbarApp"
        ),
        .testTarget(
            name: "TaskbarAppTests",
            dependencies: ["TaskbarApp"],
            path: "tests/TaskbarAppTests"
        )
    ]
)
