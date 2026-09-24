// swift-tools-version: 5.10
import PackageDescription

// Shared Elgato Prompter helpers for the Swift tools in this repo: finding the
// prompter display and switching it on through DisplayLink Manager.
let package = Package(
    name: "PrompterKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PrompterKit", targets: ["PrompterKit"])
    ],
    targets: [
        .target(
            name: "PrompterKit",
            path: "Sources/PrompterKit"
        ),
        .testTarget(
            name: "PrompterKitTests",
            dependencies: ["PrompterKit"],
            path: "tests/PrompterKitTests"
        )
    ]
)
