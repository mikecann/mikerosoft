import AVFoundation
import Foundation
import XCTest
@testable import RecordItApp

final class RecordingOutputTests: XCTestCase {
    func testBothModeCreatesSeparateTimestampedScreenAndCameraFiles() {
        let directory = URL(fileURLWithPath: "/tmp/ai-tips/source", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_721_035_800)

        let outputs = recordingOutputURLs(
            mode: .both,
            directory: directory,
            startedAt: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(outputs[.screen]?.lastPathComponent, "2024-07-15_093000-screen.mov")
        XCTAssertEqual(outputs[.camera]?.lastPathComponent, "2024-07-15_093000-camera.mov")
    }

    func testCustomBaseNameReplacesTimestampWithoutChangingSourceSuffixes() {
        let directory = URL(fileURLWithPath: "/tmp/ai-tips/source", isDirectory: true)

        let outputs = recordingOutputURLs(
            mode: .both,
            directory: directory,
            startedAt: Date(timeIntervalSince1970: 1_721_035_800),
            baseName: "episode-42"
        )

        XCTAssertEqual(outputs[.screen]?.lastPathComponent, "episode-42-screen.mov")
        XCTAssertEqual(outputs[.camera]?.lastPathComponent, "episode-42-camera.mov")
    }

    func testRecordingBaseNameTrimsWhitespaceAndAnAccidentalMovExtension() {
        XCTAssertEqual(normalizedRecordingBaseName("  launch demo.MOV  "), "launch demo")
    }

    func testRecordingBaseNameRejectsPathSeparators() {
        XCTAssertNil(normalizedRecordingBaseName("season/episode"))
        XCTAssertNil(normalizedRecordingBaseName("season:episode"))
    }

    func testVideoWriterUsesHEVCAt4K30() {
        let settings = videoOutputSettings(width: 3840, height: 2160)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]

        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 3840)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 2160)
        XCTAssertEqual(compression?[AVVideoExpectedSourceFrameRateKey] as? Int, 30)
    }
}
