import XCTest
@testable import RecordItApp

final class RecordingModeTests: XCTestCase {
    func testEachModeEnablesOnlyItsRequestedCaptureSources() {
        XCTAssertTrue(RecordingMode.screen.capturesScreen)
        XCTAssertFalse(RecordingMode.screen.capturesCamera)

        XCTAssertFalse(RecordingMode.camera.capturesScreen)
        XCTAssertTrue(RecordingMode.camera.capturesCamera)

        XCTAssertTrue(RecordingMode.both.capturesScreen)
        XCTAssertTrue(RecordingMode.both.capturesCamera)
    }
}
