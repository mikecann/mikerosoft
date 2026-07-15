import XCTest
@testable import RecordItApp

final class CaptureSelectionTests: XCTestCase {
    func testPreferredDisplayDefaultsToHG584T05() {
        let displays = [
            CaptureDisplay(id: 1, name: "LG Monitor", width: 5120, height: 2880),
            CaptureDisplay(id: 2, name: "HG584T05", width: 2560, height: 1440)
        ]

        XCTAssertEqual(preferredDisplay(in: displays)?.id, 2)
    }

    func testCameraFormatPrefersNative4KThatSupports30FPS() {
        let formats = [
            CameraFormatOption(width: 1920, height: 1080, minimumFrameRate: 1, maximumFrameRate: 60),
            CameraFormatOption(width: 3840, height: 2160, minimumFrameRate: 1, maximumFrameRate: 30),
            CameraFormatOption(width: 4096, height: 2160, minimumFrameRate: 1, maximumFrameRate: 30)
        ]

        XCTAssertEqual(preferredCameraFormat(in: formats), formats[1])
    }

    func testPreferredCameraChoosesA4K30Device() {
        let cameras = [
            CaptureCamera(id: "facetime", name: "FaceTime HD Camera", width: 1920, height: 1080),
            CaptureCamera(id: "razer", name: "Razer Kiyo Pro Ultra", width: 3840, height: 2160)
        ]

        XCTAssertEqual(preferredCamera(in: cameras)?.id, "razer")
    }

    func testPreferredCameraAudioInputDefaultsToYeti() {
        let inputs = [
            CaptureAudioDevice(id: "mac", name: "MacBook Pro Microphone"),
            CaptureAudioDevice(id: "yeti", name: "Yeti Stereo Microphone")
        ]

        XCTAssertEqual(preferredAudioDevice(in: inputs)?.id, "yeti")
    }

    @MainActor
    func testScreenAudioDefaultsToSystemPlaybackRatherThanNoAudio() {
        let model = RecordingViewModel()

        XCTAssertEqual(model.screenAudioSource, .systemSound)
        XCTAssertTrue(model.screenAudioSource.capturesSystemAudio)
        XCTAssertFalse(ScreenAudioSource.none.capturesSystemAudio)
    }
}
