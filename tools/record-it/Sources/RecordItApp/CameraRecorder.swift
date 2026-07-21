import AVFoundation
import CoreMedia
import CoreVideo

final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let camera: CaptureCamera
    private let microphone: CaptureAudioDevice?
    private let outputURL: URL
    private let encoderConfiguration: EncoderConfiguration
    private let startGate: RecordingStartGate?
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.mikerosoft.record-it.camera-session")
    private let writerQueue = DispatchQueue(label: "com.mikerosoft.record-it.camera-output")
    private var movieWriter: MovieWriter?

    init(
        camera: CaptureCamera,
        microphone: CaptureAudioDevice?,
        outputURL: URL,
        encoderConfiguration: EncoderConfiguration,
        startGate: RecordingStartGate? = nil
    ) {
        self.camera = camera
        self.microphone = microphone
        self.outputURL = outputURL
        self.encoderConfiguration = encoderConfiguration
        self.startGate = startGate
    }

    func start() async throws {
        guard await requestAccess(for: .video) else {
            throw RecordItError.message("Camera access is required. Enable it in Privacy & Security → Camera.")
        }
        if microphone != nil, !(await requestAccess(for: .audio)) {
            throw RecordItError.message("Microphone access is required for the selected camera audio input. Enable it in Privacy & Security → Microphone.")
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    try configureSession()
                    captureSession.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if captureSession.isRunning {
                    captureSession.stopRunning()
                }
                continuation.resume()
            }
        }
        writerQueue.sync {}
        guard let movieWriter else { return }
        self.movieWriter = nil
        try await movieWriter.finish()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            movieWriter?.appendVideo(sampleBuffer)
        } else if output === audioOutput {
            movieWriter?.appendAudio(sampleBuffer)
        }
    }

    private func configureSession() throws {
        guard let device = CaptureDeviceCatalog.camera(withID: camera.id) else {
            throw RecordItError.message("The selected camera is no longer available.")
        }
        guard let format = CaptureDeviceCatalog.preferredDeviceFormat(for: device) else {
            throw RecordItError.message("The selected camera has no format that supports 30 fps.")
        }
        guard let frameRateRange = format.videoSupportedFrameRateRanges.min(by: {
            abs($0.maxFrameRate - 30) < abs($1.maxFrameRate - 30)
        }) else {
            throw RecordItError.message("The selected camera did not report a usable frame duration.")
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        let videoInput = try AVCaptureDeviceInput(device: device)
        try addCameraInputThenApplySelectedFormat {
            guard captureSession.canAddInput(videoInput) else {
                throw RecordItError.message("The selected camera could not be added to the capture session.")
            }
            captureSession.addInput(videoInput)
        } applyFormat: {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = format
            device.activeVideoMinFrameDuration = frameRateRange.minFrameDuration
            device.activeVideoMaxFrameDuration = frameRateRange.minFrameDuration
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: writerQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            throw RecordItError.message("The camera video output could not be configured.")
        }
        captureSession.addOutput(videoOutput)

        var microphoneAttached = false
        if let microphone {
            guard let microphoneDevice = CaptureDeviceCatalog.audioDevice(withID: microphone.id) else {
                throw RecordItError.message("The selected microphone is no longer available.")
            }
            let audioInput = try AVCaptureDeviceInput(device: microphoneDevice)
            audioOutput.setSampleBufferDelegate(self, queue: writerQueue)
            guard captureSession.canAddInput(audioInput), captureSession.canAddOutput(audioOutput) else {
                throw RecordItError.message("The selected microphone could not be added to the camera recording.")
            }
            captureSession.addInput(audioInput)
            captureSession.addOutput(audioOutput)
            microphoneAttached = true
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        movieWriter = try MovieWriter(
            outputURL: outputURL,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            includesAudio: microphoneAttached,
            encoderConfiguration: encoderConfiguration,
            startGate: startGate
        )
    }
}

func addCameraInputThenApplySelectedFormat(
    addInput: () throws -> Void,
    applyFormat: () throws -> Void
) rethrows {
    try addInput()
    try applyFormat()
}

private func requestAccess(for mediaType: AVMediaType) async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
        return true
    case .notDetermined:
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}
