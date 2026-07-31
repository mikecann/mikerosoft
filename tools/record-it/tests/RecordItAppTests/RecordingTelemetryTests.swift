import Foundation
import XCTest
@testable import RecordItApp

final class RecordingTelemetryTests: XCTestCase {
    func testRecentVideoActivityAndSuccessfulWritesAreHealthy() {
        let telemetry = RecordingTelemetry(
            source: .screen,
            outputURL: URL(fileURLWithPath: "/tmp/demo-screen.mov"),
            width: 3840,
            height: 2160,
            codecName: "HEVC",
            videoSamplesWritten: 1_234,
            audioSamplesWritten: 2_345,
            mediaDuration: 42,
            fileSizeBytes: 8_000_000,
            lastVideoActivityAt: 100,
            consecutiveRejectedVideoSamples: 0,
            writerStatus: .writing,
            now: 100.5
        )

        XCTAssertEqual(telemetry.health, .healthy)
        XCTAssertEqual(telemetry.healthMessage, "Video and file output are active")
        XCTAssertEqual(telemetry.resolutionLabel, "3840 × 2160")
        XCTAssertEqual(telemetry.outputFileName, "demo-screen.mov")
    }

    func testDashboardWarnsBeforeTheCaptureWatchdogStopsAStalledRecording() {
        let warning = RecordingTelemetry(
            source: .screen,
            outputURL: URL(fileURLWithPath: "/tmp/demo-screen.mov"),
            width: 3840,
            height: 2160,
            codecName: "HEVC",
            videoSamplesWritten: 100,
            audioSamplesWritten: 200,
            mediaDuration: 12,
            fileSizeBytes: 1_000,
            lastVideoActivityAt: 100,
            consecutiveRejectedVideoSamples: 0,
            writerStatus: .writing,
            now: 104
        )
        let failed = RecordingTelemetry(
            source: .screen,
            outputURL: URL(fileURLWithPath: "/tmp/demo-screen.mov"),
            width: 3840,
            height: 2160,
            codecName: "HEVC",
            videoSamplesWritten: 100,
            audioSamplesWritten: 200,
            mediaDuration: 12,
            fileSizeBytes: 1_000,
            lastVideoActivityAt: 100,
            consecutiveRejectedVideoSamples: 60,
            writerStatus: .writing,
            now: 104
        )

        XCTAssertEqual(warning.health, .warning)
        XCTAssertEqual(warning.healthMessage, "Waiting for the next video update")
        XCTAssertEqual(failed.health, .failed)
        XCTAssertEqual(failed.healthMessage, "Video encoder is not accepting frames")
    }

    func testRecordingModeReplacesConfigurationWithTheLiveDashboard() {
        XCTAssertFalse(shouldShowRecordingDashboard(isRecording: false, isBusy: false))
        XCTAssertTrue(shouldShowRecordingDashboard(isRecording: true, isBusy: false))
        XCTAssertTrue(shouldShowRecordingDashboard(isRecording: true, isBusy: true))
    }

    func testOverallHealthDoesNotClaimHealthyUntilEverySourceIsHealthy() {
        XCTAssertEqual(overallRecordingHealth([.healthy, .starting]), .starting)
        XCTAssertEqual(overallRecordingHealth([.healthy, .warning]), .warning)
        XCTAssertEqual(overallRecordingHealth([.healthy, .failed]), .failed)
        XCTAssertEqual(overallRecordingHealth([.healthy, .healthy]), .healthy)
    }

    func testAudioTelemetryBecomesHealthyAfterReceivingInputSamples() {
        let telemetry = RecordingTelemetry(
            source: .audio,
            outputURL: URL(fileURLWithPath: "/tmp/voice-over-audio.m4a"),
            width: 0,
            height: 0,
            codecName: "AAC",
            videoSamplesWritten: 0,
            audioSamplesWritten: 42,
            mediaDuration: 1.25,
            fileSizeBytes: 4_096,
            lastVideoActivityAt: 100,
            consecutiveRejectedVideoSamples: 0,
            writerStatus: .writing,
            now: 101,
            audioWaveformLevels: [0.1, 0.5, 0.9]
        )

        XCTAssertEqual(telemetry.health, .healthy)
        XCTAssertEqual(telemetry.healthMessage, "Audio and file output are active")
        XCTAssertEqual(telemetry.resolutionLabel, "Audio only")
        XCTAssertEqual(telemetry.audioWaveformLevels, [0.1, 0.5, 0.9])
    }

    func testAudioTelemetryWarnsWhenTheInputHasStayedSilent() {
        let telemetry = RecordingTelemetry(
            source: .audio,
            outputURL: URL(fileURLWithPath: "/tmp/voice-over-audio.m4a"),
            width: 0,
            height: 0,
            codecName: "AAC",
            videoSamplesWritten: 0,
            audioSamplesWritten: 300,
            mediaDuration: 3,
            fileSizeBytes: 4_096,
            lastVideoActivityAt: 100,
            consecutiveRejectedVideoSamples: 0,
            writerStatus: .writing,
            now: 100,
            audioWaveformLevels: Array(repeating: 0.02, count: 30)
        )

        XCTAssertEqual(telemetry.health, .warning)
        XCTAssertEqual(
            telemetry.healthMessage,
            "Input is silent. Check the selected microphone, mute, and gain"
        )
    }
}
