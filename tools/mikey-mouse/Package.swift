// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MikeyMouse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "mikey-mouse", targets: ["MikeyMouse"])
    ],
    targets: [
        .executableTarget(
            name: "MikeyMouse",
            path: "Sources/MikeyMouse"
        ),
        .testTarget(
            name: "MikeyMouseTests",
            dependencies: ["MikeyMouse"],
            path: "Tests/MikeyMouseTests"
        )
    ]
)
