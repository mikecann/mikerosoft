// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Phonebooth",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "phonebooth-swift", targets: ["PhoneboothApp"])
    ],
    targets: [
        .executableTarget(
            name: "PhoneboothApp",
            path: "Sources/PhoneboothApp"
        ),
        .testTarget(
            name: "PhoneboothAppTests",
            dependencies: ["PhoneboothApp"],
            path: "tests/PhoneboothAppTests"
        )
    ]
)
