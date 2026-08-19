import AVFoundation
import CoreMedia
import CoreVideo

final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let camera: CaptureCamera
    private let microphone: CaptureAudioDevice?
    private let outputURL: URL
    private let encoderConfiguration: EncoderConfiguration
    private let startGate: RecordingStartGate?
    private let onFailure: (@Sendable (Error) -> Void)?
    private let onTelemetry: (@Sendable (RecordingTelemetry) -> Void)?
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.mikerosoft.record-it.camera-session")
    private let writerQueue = DispatchQueue(label: "com.mikerosoft.record-it.camera-output")
    private var movieWriter: MovieWriter?
    private var healthState: MediaCaptureHealthState?
    private var healthTimer: DispatchSourceTimer?
    private var lastWaveformSampleAt: TimeInterval?
    private var waveform = AudioWaveformBuffer(capacity: 120)
    private var isStopping = false
    private var captureError: Error?
    private var configurationLockedDevice: AVCaptureDevice?

    init(
        camera: CaptureCamera,
        microphone: CaptureAudioDevice?,
        outputURL: URL,
        encoderConfiguration: EncoderConfiguration,
        startGate: RecordingStartGate? = nil,
        onFailure: (@Sendable (Error) -> Void)? = nil,
        onTelemetry: (@Sendable (RecordingTelemetry) -> Void)? = nil
    ) {
        self.camera = camera
        self.microphone = microphone
        self.outputURL = outputURL
        self.encoderConfiguration = encoderConfiguration
        self.startGate = startGate
        self.onFailure = onFailure
        self.onTelemetry = onTelemetry
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
                    startHealthMonitor()
                    RecordingDiagnostics.shared.log(
                        "camera.start device=\(camera.name) output=\(camera.width)x\(camera.height) "
                            + "microphone=\(microphone?.name ?? "none") "
                            + "encoder=\(encoderConfiguration.encoder.displayName)"
                    )
                    let activeFormat = configurationLockedDevice?.activeFormat
                    if let activeFormat {
                        let dimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
                        let duration = configurationLockedDevice?.activeVideoMinFrameDuration ?? .invalid
                        let frameRate = duration.seconds > 0 ? 1 / duration.seconds : 0
                        RecordingDiagnostics.shared.log(
                            "camera.running format=\(dimensions.width)x\(dimensions.height) "
                                + "fps=\(String(format: "%.6f", frameRate))"
                        )
                    }
                    continuation.resume()
                } catch {
                    releaseDeviceConfigurationLock()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
        writerQueue.sync {
            isStopping = true
            healthTimer?.cancel()
            healthTimer = nil
        }
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if captureSession.isRunning {
                    captureSession.stopRunning()
                }
                releaseDeviceConfigurationLock()
                continuation.resume()
            }
        }
        writerQueue.sync {}
        guard let movieWriter else { return }
        self.movieWriter = nil
        try await movieWriter.finish()
        RecordingDiagnostics.shared.log("camera.stop error=\(captureError?.localizedDescription ?? "none")")
        if let captureError { throw captureError }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            let now = ProcessInfo.processInfo.systemUptime
            healthState?.recordScreenCallback(at: now)
            let accepted = movieWriter?.appendVideo(sampleBuffer) ?? false
            let waitingForSharedStart = startGate != nil && startGate?.startTime == nil
            healthState?.recordVideoAppend(accepted: accepted || waitingForSharedStart)
            reportHealthProblemIfNeeded(at: now)
        } else if output === audioOutput {
            let now = ProcessInfo.processInfo.systemUptime
            do {
                try withAudioPCMBuffer(from: sampleBuffer) { [self] buffer in
                    let peak = peakDecibels(in: buffer)
                    let waitingForSharedStart = startGate != nil && startGate?.startTime == nil
                    let accepted = movieWriter?.appendAudio(sampleBuffer) ?? false
                    healthState?.recordAudioCallback(
                        at: now,
                        accepted: accepted || waitingForSharedStart,
                        peakDecibels: peak
                    )
                    if lastWaveformSampleAt == nil || now - (lastWaveformSampleAt ?? 0) >= 0.1 {
                        waveform.append(decibels: peak)
                        lastWaveformSampleAt = now
                    }
                }
            } catch {
                reportFailure(error)
                return
            }
            reportHealthProblemIfNeeded(at: now)
        }
    }

    private func startHealthMonitor() {
        writerQueue.async { [weak self] in
            guard let self, !isStopping else { return }
            let now = ProcessInfo.processInfo.systemUptime
            healthState = MediaCaptureHealthState(
                startedAt: now,
                requiresAudio: microphone != nil,
                failsOnDigitalSilence: microphone != nil
            )
            let timer = DispatchSource.makeTimerSource(queue: writerQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                emitTelemetry(at: now)
                reportHealthProblemIfNeeded(at: now)
            }
            healthTimer = timer
            timer.resume()
        }
    }

    private func reportHealthProblemIfNeeded(at time: TimeInterval) {
        guard let problem = healthState?.problem(at: time) else { return }
        reportFailure(RecordItError.message(problem))
    }

    private func reportFailure(_ error: Error) {
        guard !isStopping, captureError == nil else { return }
        captureError = error
        healthTimer?.cancel()
        healthTimer = nil
        RecordingDiagnostics.shared.log("camera.failure error=\(error.localizedDescription)")
        emitTelemetry(at: ProcessInfo.processInfo.systemUptime, failureMessage: error.localizedDescription)
        onFailure?(error)
    }

    private func emitTelemetry(at time: TimeInterval, failureMessage: String? = nil) {
        guard let movieWriter else { return }
        let progress = movieWriter.progress()
        onTelemetry?(RecordingTelemetry(
            source: .camera,
            outputURL: outputURL,
            width: camera.width,
            height: camera.height,
            codecName: encoderConfiguration.encoder.codec.displayName,
            videoSamplesWritten: progress.videoSamplesWritten,
            audioSamplesWritten: progress.audioSamplesWritten,
            mediaDuration: progress.mediaDuration,
            fileSizeBytes: progress.fileSizeBytes,
            lastVideoActivityAt: healthState?.lastScreenCallbackAt,
            consecutiveRejectedVideoSamples: healthState?.consecutiveRejectedFrames ?? 0,
            writerStatus: progress.writerStatus,
            now: time,
            audioWaveformLevels: waveform.levels,
            failureMessage: failureMessage
        ))
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
            configurationLockedDevice = device
            // macOS may replace an explicitly selected format when the session
            // starts unless the device stays locked for the capture lifetime.
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

    private func releaseDeviceConfigurationLock() {
        configurationLockedDevice?.unlockForConfiguration()
        configurationLockedDevice = nil
    }
}

func addCameraInputThenApplySelectedFormat(
    addInput: () throws -> Void,
    applyFormat: () throws -> Void
) rethrows {
    try addInput()
    try applyFormat()
}

func requestAccess(for mediaType: AVMediaType) async -> Bool {
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
