import AVFoundation
import CoreMedia

final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let audioDevice: CaptureAudioDevice
    private let outputURL: URL
    private let onFailure: (@Sendable (Error) -> Void)?
    private let onTelemetry: (@Sendable (RecordingTelemetry) -> Void)?
    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.mikerosoft.record-it.audio-session")
    private let writerQueue = DispatchQueue(label: "com.mikerosoft.record-it.audio-output")
    private var audioWriter: AudioWriter?
    private var healthTimer: DispatchSourceTimer?
    private var startedAt: TimeInterval?
    private var lastAudioActivityAt: TimeInterval?
    private var lastWaveformSampleAt: TimeInterval?
    private var waveform = AudioWaveformBuffer(capacity: 72)
    private var isStopping = false
    private var captureError: Error?

    init(
        audioDevice: CaptureAudioDevice,
        outputURL: URL,
        onFailure: (@Sendable (Error) -> Void)? = nil,
        onTelemetry: (@Sendable (RecordingTelemetry) -> Void)? = nil
    ) {
        self.audioDevice = audioDevice
        self.outputURL = outputURL
        self.onFailure = onFailure
        self.onTelemetry = onTelemetry
    }

    func start() async throws {
        guard await requestAccess(for: .audio) else {
            throw RecordItError.message(
                "Microphone access is required for audio recording. Enable it in Privacy & Security → Microphone."
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    try configureSession()
                    captureSession.startRunning()
                    startHealthMonitor()
                    RecordingDiagnostics.shared.log(
                        "audio.start device=\(audioDevice.name) output=\(outputURL.lastPathComponent)"
                    )
                    continuation.resume()
                } catch {
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
                continuation.resume()
            }
        }
        writerQueue.sync {}
        guard let audioWriter else { return }
        self.audioWriter = nil
        try await audioWriter.finish()
        RecordingDiagnostics.shared.log("audio.stop error=\(captureError?.localizedDescription ?? "none")")
        if let captureError { throw captureError }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lastAudioActivityAt = now
        _ = audioWriter?.appendAudio(sampleBuffer)
        if lastWaveformSampleAt == nil || now - (lastWaveformSampleAt ?? 0) >= 0.1 {
            let decibels = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
            waveform.append(decibels: decibels)
            lastWaveformSampleAt = now
        }
    }

    private func configureSession() throws {
        guard let device = CaptureDeviceCatalog.audioDevice(withID: audioDevice.id) else {
            throw RecordItError.message("The selected audio input is no longer available.")
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        audioOutput.setSampleBufferDelegate(self, queue: writerQueue)
        guard captureSession.canAddInput(input), captureSession.canAddOutput(audioOutput) else {
            throw RecordItError.message("The selected audio input could not be configured.")
        }
        captureSession.addInput(input)
        captureSession.addOutput(audioOutput)
        audioWriter = try AudioWriter(outputURL: outputURL)
    }

    private func startHealthMonitor() {
        writerQueue.async { [weak self] in
            guard let self, !isStopping else { return }
            startedAt = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: writerQueue)
            timer.schedule(
                deadline: .now() + .milliseconds(100),
                repeating: .milliseconds(100),
                leeway: .milliseconds(20)
            )
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                emitTelemetry(at: now)
                if let startedAt, now - (lastAudioActivityAt ?? startedAt) >= 10 {
                    reportFailure(RecordItError.message("No audio input was received for 10 seconds."))
                }
            }
            healthTimer = timer
            timer.resume()
        }
    }

    private func emitTelemetry(at time: TimeInterval, failureMessage: String? = nil) {
        guard let audioWriter else { return }
        let progress = audioWriter.progress()
        onTelemetry?(RecordingTelemetry(
            source: .audio,
            outputURL: outputURL,
            width: 0,
            height: 0,
            codecName: "AAC",
            videoSamplesWritten: 0,
            audioSamplesWritten: progress.audioSamplesWritten,
            mediaDuration: progress.mediaDuration,
            fileSizeBytes: progress.fileSizeBytes,
            lastVideoActivityAt: lastAudioActivityAt ?? startedAt,
            consecutiveRejectedVideoSamples: 0,
            writerStatus: progress.writerStatus,
            now: time,
            audioWaveformLevels: waveform.levels,
            failureMessage: failureMessage
        ))
    }

    private func reportFailure(_ error: Error) {
        guard !isStopping, captureError == nil else { return }
        captureError = error
        healthTimer?.cancel()
        healthTimer = nil
        RecordingDiagnostics.shared.log("audio.failure error=\(error.localizedDescription)")
        emitTelemetry(at: ProcessInfo.processInfo.systemUptime, failureMessage: error.localizedDescription)
        onFailure?(error)
    }
}
