// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RecordIt",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "record-it-swift", targets: ["RecordItApp"])
    ],
    targets: [
        .executableTarget(
            name: "RecordItApp",
            path: "Sources/RecordItApp"
        ),
        .testTarget(
            name: "RecordItAppTests",
            dependencies: ["RecordItApp"],
            path: "tests/RecordItAppTests"
        )
    ]
)
