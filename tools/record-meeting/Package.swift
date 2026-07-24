// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecordMeeting",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "record-meeting-swift", targets: ["RecordMeetingApp"])
    ],
    targets: [
        .executableTarget(
            name: "RecordMeetingApp",
            path: "Sources/RecordMeetingApp"
        ),
        .testTarget(
            name: "RecordMeetingAppTests",
            dependencies: ["RecordMeetingApp"],
            path: "tests/RecordMeetingAppTests"
        )
    ]
)
