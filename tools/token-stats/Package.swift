// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TokenStats",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "token-stats-swift", targets: ["TokenStatsApp"])
    ],
    targets: [
        .executableTarget(
            name: "TokenStatsApp",
            path: "Sources/TokenStatsApp"
        ),
        .testTarget(
            name: "TokenStatsAppTests",
            dependencies: ["TokenStatsApp"],
            path: "tests/TokenStatsAppTests"
        )
    ]
)
