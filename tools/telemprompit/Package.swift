// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Telemprompit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "telemprompit", targets: ["TelemprompitApp"])
    ],
    dependencies: [
        .package(path: "../lib/PrompterKit")
    ],
    targets: [
        .executableTarget(
            name: "TelemprompitApp",
            dependencies: [
                .product(name: "PrompterKit", package: "PrompterKit")
            ],
            path: "Sources/TelemprompitApp"
        ),
        .testTarget(
            name: "TelemprompitAppTests",
            dependencies: ["TelemprompitApp"],
            path: "tests/TelemprompitAppTests"
        )
    ]
)
