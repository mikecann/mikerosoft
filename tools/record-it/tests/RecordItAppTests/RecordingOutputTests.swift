import AVFoundation
import Foundation
import VideoToolbox
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

    func testAudioModeCreatesAnM4AAudioFileWithoutVideoOutputs() {
        let directory = URL(fileURLWithPath: "/tmp/ai-tips/source", isDirectory: true)

        let outputs = recordingOutputURLs(
            mode: .audio,
            directory: directory,
            startedAt: Date(timeIntervalSince1970: 1_721_035_800),
            baseName: "voice-over"
        )

        XCTAssertEqual(outputs, [
            .audio: directory.appendingPathComponent("voice-over-audio.m4a")
        ])
    }

    func testRecordingBaseNameTrimsWhitespaceAndAnAccidentalMovExtension() {
        XCTAssertEqual(normalizedRecordingBaseName("  launch demo.MOV  "), "launch demo")
        XCTAssertEqual(normalizedRecordingBaseName("  voice over.M4A  "), "voice over")
    }

    func testRecordingBaseNameRejectsPathSeparators() {
        XCTAssertNil(normalizedRecordingBaseName("season/episode"))
        XCTAssertNil(normalizedRecordingBaseName("season:episode"))
    }

    func testVideoWriterUsesTheSelectedHardwareEncoderAt4K30() {
        let configuration = encoderConfiguration(rateControl: .vbr)
        let settings = videoOutputSettings(width: 3840, height: 2160, configuration: configuration)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        let encoderSpecification = settings[AVVideoEncoderSpecificationKey] as? [String: Any]

        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 3840)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 2160)
        XCTAssertEqual(compression?[AVVideoExpectedSourceFrameRateKey] as? Int, 30)
        XCTAssertEqual(
            encoderSpecification?[kVTVideoEncoderSpecification_EncoderID as String] as? String,
            configuration.encoder.id
        )
    }

    func testCBRUsesTheConstantBitRateProperty() {
        let settings = videoOutputSettings(
            width: 3840,
            height: 2160,
            configuration: encoderConfiguration(rateControl: .cbr)
        )
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]

        XCTAssertEqual(compression?[kVTCompressionPropertyKey_ConstantBitRate as String] as? Int, 60_000_000)
        XCTAssertNil(compression?[kVTCompressionPropertyKey_AverageBitRate as String])
    }

    func testCQPUsesMatchingMinimumAndMaximumFrameQP() {
        let settings = videoOutputSettings(
            width: 3840,
            height: 2160,
            configuration: encoderConfiguration(rateControl: .cqp)
        )
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]

        XCTAssertEqual(compression?[kVTCompressionPropertyKey_MinAllowedFrameQP as String] as? Int, 20)
        XCTAssertEqual(compression?[kVTCompressionPropertyKey_MaxAllowedFrameQP as String] as? Int, 20)
    }

    func testVBRUsesTargetAndMaximumBitRates() {
        guard #available(macOS 26.0, *) else { return }
        let settings = videoOutputSettings(
            width: 3840,
            height: 2160,
            configuration: encoderConfiguration(rateControl: .vbr)
        )
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]

        XCTAssertEqual(compression?[kVTCompressionPropertyKey_VariableBitRate as String] as? Int, 60_000_000)
        XCTAssertEqual(compression?[kVTCompressionPropertyKey_VBVMaxBitRate as String] as? Int, 80_000_000)
    }
}

private func encoderConfiguration(rateControl: RateControlMode) -> EncoderConfiguration {
    EncoderConfiguration(
        encoder: HardwareVideoEncoder(
            id: "com.apple.videotoolbox.videoencoder.ave.hevc",
            displayName: "Apple HEVC (HW)",
            codec: .hevc,
            supportedRateControls: Set(RateControlMode.allCases)
        ),
        rateControl: rateControl,
        bitRateMbps: 60,
        maximumBitRateMbps: 80,
        qualityParameter: 20
    )
}
