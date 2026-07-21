import AVFoundation
import XCTest
@testable import RecordItApp

@MainActor
final class CameraPreviewTests: XCTestCase {
    func testPreviewButtonRequiresAnIdleSelectedCamera() {
        XCTAssertFalse(cameraPreviewButtonIsDisabled(
            hasSelectedCamera: true,
            isRecording: false,
            isBusy: false
        ))
        XCTAssertTrue(cameraPreviewButtonIsDisabled(
            hasSelectedCamera: false,
            isRecording: false,
            isBusy: false
        ))
        XCTAssertTrue(cameraPreviewButtonIsDisabled(
            hasSelectedCamera: true,
            isRecording: true,
            isBusy: false
        ))
        XCTAssertTrue(cameraPreviewButtonIsDisabled(
            hasSelectedCamera: true,
            isRecording: false,
            isBusy: true
        ))
    }

    func testPreviewStartsAndStopsTheSelectedCameraSession() async {
        let controller = FakeCameraPreviewSessionController()
        let model = CameraPreviewModel(cameraID: "razer", controller: controller)

        await model.start()

        XCTAssertEqual(controller.startedCameraIDs, ["razer"])
        XCTAssertEqual(model.state, .running)

        await model.stop()

        XCTAssertEqual(controller.stopCallCount, 1)
        XCTAssertEqual(model.state, .idle)
    }

    func testPreviewReportsCameraStartupErrors() async {
        let controller = FakeCameraPreviewSessionController()
        controller.startError = RecordItError.message("Camera unavailable")
        let model = CameraPreviewModel(cameraID: "missing", controller: controller)

        await model.start()

        XCTAssertEqual(model.state, .failed("Camera unavailable"))
    }
}

private final class FakeCameraPreviewSessionController: CameraPreviewSessionControlling {
    let session = AVCaptureSession()
    var startedCameraIDs: [String] = []
    var stopCallCount = 0
    var startError: Error?

    func start(cameraID: String) async throws {
        startedCameraIDs.append(cameraID)
        if let startError { throw startError }
    }

    func stop() async {
        stopCallCount += 1
    }
}
