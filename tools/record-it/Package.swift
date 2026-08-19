// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RecordIt",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "record-it-swift", targets: ["RecordItApp"]),
        .executable(name: "record-it-recovery-audio", targets: ["RecordItRecoveryAudio"])
    ],
    targets: [
        .executableTarget(
            name: "RecordItApp",
            path: "Sources/RecordItApp"
        ),
        .executableTarget(
            name: "RecordItRecoveryAudio",
            path: "Sources/RecordItRecoveryAudio"
        ),
        .testTarget(
            name: "RecordItAppTests",
            dependencies: ["RecordItApp"],
            path: "tests/RecordItAppTests"
        )
    ]
)
