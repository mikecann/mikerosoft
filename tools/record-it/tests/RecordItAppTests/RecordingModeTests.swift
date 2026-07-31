import XCTest
@testable import RecordItApp

final class RecordingModeTests: XCTestCase {
    func testEachModeEnablesOnlyItsRequestedCaptureSources() {
        XCTAssertTrue(RecordingMode.screen.capturesScreen)
        XCTAssertFalse(RecordingMode.screen.capturesCamera)
        XCTAssertFalse(RecordingMode.screen.capturesAudio)

        XCTAssertFalse(RecordingMode.camera.capturesScreen)
        XCTAssertTrue(RecordingMode.camera.capturesCamera)
        XCTAssertFalse(RecordingMode.camera.capturesAudio)

        XCTAssertTrue(RecordingMode.both.capturesScreen)
        XCTAssertTrue(RecordingMode.both.capturesCamera)
        XCTAssertFalse(RecordingMode.both.capturesAudio)

        XCTAssertFalse(RecordingMode.audio.capturesScreen)
        XCTAssertFalse(RecordingMode.audio.capturesCamera)
        XCTAssertTrue(RecordingMode.audio.capturesAudio)
    }

    func testOnlyVideoModesRequireAHardwareVideoEncoder() {
        XCTAssertTrue(RecordingMode.screen.requiresVideoEncoder)
        XCTAssertTrue(RecordingMode.camera.requiresVideoEncoder)
        XCTAssertTrue(RecordingMode.both.requiresVideoEncoder)
        XCTAssertFalse(RecordingMode.audio.requiresVideoEncoder)
    }
}
