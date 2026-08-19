import Foundation
import XCTest
@testable import RecordItApp

@MainActor
final class RecordingViewModelTests: XCTestCase {
    func testCriticalCaptureFailureMessageSaysTheRecordingIsNotUsable() {
        XCTAssertEqual(
            criticalCaptureFailureMessage(
                source: .camera,
                reason: "The microphone stayed silent for 10 seconds."
            ),
            "CAMERA CAPTURE FAILED. RECORDING STOPPED. VIDEO AND AUDIO ARE NOT COMPLETE. "
                + "Do not continue this take. The microphone stayed silent for 10 seconds."
        )
    }

    func testCriticalFailurePointsToTheTemporaryRecoveryTrack() {
        let recoveryURL = URL(fileURLWithPath: "/recovery/take-backup-audio.caf")

        XCTAssertTrue(
            criticalCaptureFailureMessage(
                source: .camera,
                reason: "The primary microphone froze.",
                recoveryAudioURL: recoveryURL
            ).contains("Recovery audio may be available at: /recovery/take-backup-audio.caf")
        )
    }

    func testViewModelRestoresTheLastSelectedRecordingMode() {
        let suiteName = "record-it-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RecordingPreferences(defaults: defaults)
        preferences.recordingMode = .camera

        let model = RecordingViewModel(preferences: preferences)

        XCTAssertEqual(model.mode, .camera)
    }

    func testDefaultProjectsRootUsesTheConvexVideosDirectory() {
        let homeDirectory = URL(fileURLWithPath: "/Users/m5-mike", isDirectory: true)

        XCTAssertEqual(
            defaultProjectsRoot(homeDirectory: homeDirectory),
            URL(fileURLWithPath: "/Users/m5-mike/dev/convex/convex-videos", isDirectory: true)
        )
    }

    func testDisplayConfigurationRefreshUpdatesResolutionAndKeepsTheSelectedDisplay() {
        var connectedDisplays = [
            CaptureDisplay(id: 1, name: "LG Monitor", width: 5120, height: 2880),
            CaptureDisplay(id: 2, name: "PA27JCV", width: 3200, height: 1800)
        ]
        let model = RecordingViewModel(displayProvider: { connectedDisplays })

        model.refreshDisplaysAfterSystemChange()
        XCTAssertEqual(model.selectedDisplayID, 2)
        XCTAssertEqual(model.selectedDisplay?.resolutionLabel, "3200 × 1800")

        connectedDisplays = [
            CaptureDisplay(id: 1, name: "LG Monitor", width: 5120, height: 2880),
            CaptureDisplay(id: 2, name: "PA27JCV", width: 2560, height: 1440)
        ]
        model.refreshDisplaysAfterSystemChange()

        XCTAssertEqual(model.selectedDisplayID, 2)
        XCTAssertEqual(model.selectedDisplay?.resolutionLabel, "2560 × 1440")
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

    func testRecordButtonIsDisabledWhileCameraPreviewIsOpen() {
        XCTAssertTrue(
            recordButtonIsDisabled(
                canRecord: true,
                isRecording: false,
                isBusy: false,
                isCameraPreviewOpen: true
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

    func testAudioModeNeedsAnInputButDoesNotNeedVideoDevicesOrAnEncoder() {
        XCTAssertTrue(recordingPrerequisitesAreAvailable(
            mode: .audio,
            screenCaptureTargetKind: .display,
            hasDestination: true,
            hasValidFileName: true,
            hasVideoEncoder: false,
            hasDisplay: false,
            hasWindow: false,
            hasCamera: false,
            hasAudioInput: true,
            isBusy: false
        ))
        XCTAssertFalse(recordingPrerequisitesAreAvailable(
            mode: .audio,
            screenCaptureTargetKind: .display,
            hasDestination: true,
            hasValidFileName: true,
            hasVideoEncoder: false,
            hasDisplay: false,
            hasWindow: false,
            hasCamera: false,
            hasAudioInput: false,
            isBusy: false
        ))
    }

    func testCameraModeCannotStartWithoutASeparateRecoveryMicrophone() {
        XCTAssertFalse(recordingPrerequisitesAreAvailable(
            mode: .camera,
            screenCaptureTargetKind: .display,
            hasDestination: true,
            hasValidFileName: true,
            hasVideoEncoder: true,
            hasDisplay: false,
            hasWindow: false,
            hasCamera: true,
            hasAudioInput: true,
            hasRecoveryAudioInput: false,
            isBusy: false
        ))
    }

    func testCameraModeCannotStartWithoutPrimaryAudio() {
        XCTAssertFalse(recordingPrerequisitesAreAvailable(
            mode: .camera,
            screenCaptureTargetKind: .display,
            hasDestination: true,
            hasValidFileName: true,
            hasVideoEncoder: true,
            hasDisplay: false,
            hasWindow: false,
            hasCamera: true,
            hasAudioInput: false,
            hasRecoveryAudioInput: true,
            isBusy: false
        ))
    }

    func testScreenModeAcceptsASelectedWindowWithoutASelectedDisplay() {
        XCTAssertTrue(recordingPrerequisitesAreAvailable(
            mode: .screen,
            screenCaptureTargetKind: .window,
            hasDestination: true,
            hasValidFileName: true,
            hasVideoEncoder: true,
            hasDisplay: false,
            hasWindow: true,
            hasCamera: false,
            hasAudioInput: false,
            isBusy: false
        ))

        XCTAssertFalse(recordingPrerequisitesAreAvailable(
            mode: .screen,
            screenCaptureTargetKind: .window,
            hasDestination: true,
            hasValidFileName: true,
            hasVideoEncoder: true,
            hasDisplay: true,
            hasWindow: false,
            hasCamera: false,
            hasAudioInput: false,
            isBusy: false
        ))
    }
}
