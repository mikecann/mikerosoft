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
}
