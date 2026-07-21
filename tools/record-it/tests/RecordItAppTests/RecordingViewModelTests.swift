import Foundation
import XCTest
@testable import RecordItApp

@MainActor
final class RecordingViewModelTests: XCTestCase {
    func testDefaultProjectsRootUsesTheConvexVideosDirectory() {
        let homeDirectory = URL(fileURLWithPath: "/Users/m5-mike", isDirectory: true)

        XCTAssertEqual(
            defaultProjectsRoot(homeDirectory: homeDirectory),
            URL(fileURLWithPath: "/Users/m5-mike/dev/convex/convex-videos", isDirectory: true)
        )
    }

    func testRecordButtonIsDisabledWhileARecordingOperationIsBusy() {
        XCTAssertTrue(
            recordButtonIsDisabled(
                canRecord: false,
                isRecording: true,
                isBusy: true
            )
        )
    }

    func testResetFileNameReplacesAnOverrideWithTheCurrentTimestampDefault() {
        let model = RecordingViewModel()
        model.fileName = "launch-demo"

        model.resetFileName(
            at: Date(timeIntervalSince1970: 1_721_035_800),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(model.fileName, "2024-07-15_093000")
    }
}
