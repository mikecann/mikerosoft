// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhoneMirror",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "phone-mirror-swift", targets: ["PhoneMirrorApp"])
    ],
    targets: [
        .executableTarget(
            name: "PhoneMirrorApp",
            path: "Sources/PhoneMirrorApp"
        ),
        .testTarget(
            name: "PhoneMirrorAppTests",
            dependencies: ["PhoneMirrorApp"],
            path: "tests/PhoneMirrorAppTests"
        )
    ]
)
