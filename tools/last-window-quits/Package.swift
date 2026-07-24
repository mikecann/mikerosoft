// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LastWindowQuits",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "last-window-quits", targets: ["LastWindowQuits"])
    ],
    targets: [
        .executableTarget(
            name: "LastWindowQuits",
            path: "Sources/LastWindowQuits"
        ),
        .testTarget(
            name: "LastWindowQuitsTests",
            dependencies: ["LastWindowQuits"],
            path: "Tests/LastWindowQuitsTests"
        )
    ]
)
