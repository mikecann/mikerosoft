// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeetingArchive",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingArchiveCore", targets: ["MeetingArchiveCore"]),
        .executable(name: "meeting-archive-app", targets: ["MeetingArchiveApp"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/MeetingArchiveCore/CSQLite"
        ),
        .target(
            name: "MeetingArchiveCore",
            dependencies: ["CSQLite"],
            path: "Sources/MeetingArchiveCore",
            exclude: ["CSQLite"]
        ),
        .executableTarget(
            name: "MeetingArchiveApp",
            dependencies: ["MeetingArchiveCore"]
        ),
        .testTarget(
            name: "MeetingArchiveCoreTests",
            dependencies: ["MeetingArchiveCore"]
        ),
        .testTarget(
            name: "MeetingArchiveAppTests",
            dependencies: ["MeetingArchiveApp"],
            path: "Tests/MeetingArchiveAppTests"
        ),
    ]
)
