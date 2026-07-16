// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VideoHQ",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "video-hq", targets: ["VideoHQApp"])
    ],
    targets: [
        .executableTarget(
            name: "VideoHQApp",
            path: "Sources/VideoHQApp"
        ),
        .testTarget(
            name: "VideoHQAppTests",
            dependencies: ["VideoHQApp"],
            path: "tests/VideoHQAppTests"
        )
    ]
)
