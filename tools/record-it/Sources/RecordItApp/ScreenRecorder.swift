import AVFoundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let target: ScreenCaptureTarget
    private let audioSource: ScreenAudioSource
    private let outputURL: URL
    private let encoderConfiguration: EncoderConfiguration
    private let startGate: RecordingStartGate?
    private let onFailure: (@Sendable (Error) -> Void)?
    private let onTelemetry: (@Sendable (RecordingTelemetry) -> Void)?
    private let outputQueue = DispatchQueue(label: "com.mikerosoft.record-it.screen-output")
    private var stream: SCStream?
    private var movieWriter: MovieWriter?
    private var streamError: Error?
    private var healthState: ScreenCaptureHealthState?
    private var healthTimer: DispatchSourceTimer?
    private var isStopping = false
    private var lastFrameStatus: SCFrameStatus?
    private var latestScreenTimestamp: CMTime?
    private var lastHealthLogAt: TimeInterval?
    private var captureWidth = 0
    private var captureHeight = 0

    init(
        target: ScreenCaptureTarget,
        audioSource: ScreenAudioSource,
        outputURL: URL,
        encoderConfiguration: EncoderConfiguration,
        startGate: RecordingStartGate? = nil,
        onFailure: (@Sendable (Error) -> Void)? = nil,
        onTelemetry: (@Sendable (RecordingTelemetry) -> Void)? = nil
    ) {
        self.target = target
        self.audioSource = audioSource
        self.outputURL = outputURL
        self.encoderConfiguration = encoderConfiguration
        self.startGate = startGate
        self.onFailure = onFailure
        self.onTelemetry = onTelemetry
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecordItError.message(
                "Screen Recording access is required. Enable Record It in Privacy & Security → Screen & System Audio Recording, then relaunch the app."
            )
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let filter: SCContentFilter
        let pixelSize: CapturePixelSize
        let targetDescription: String
        switch target {
        case .display(let display):
            guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
                throw RecordItError.message("The selected display is no longer available.")
            }
            filter = SCContentFilter(
                display: scDisplay,
                excludingApplications: [],
                exceptingWindows: []
            )
            pixelSize = CapturePixelSize(width: display.width, height: display.height)
            targetDescription = "display=\(display.name)"
        case .window(let window):
            guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
                throw RecordItError.message("The selected window is no longer available.")
            }
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            pixelSize = windowCapturePixelSize(
                widthInPoints: filter.contentRect.width,
                heightInPoints: filter.contentRect.height,
                pointPixelScale: filter.pointPixelScale
            )
            targetDescription = "window=\(window.applicationName)/\(window.title)"
        }

        let writer = try MovieWriter(
            outputURL: outputURL,
            width: pixelSize.width,
            height: pixelSize.height,
            includesAudio: audioSource.capturesSystemAudio,
            encoderConfiguration: encoderConfiguration,
            startGate: startGate
        )
        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.capturesAudio = audioSource.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if audioSource.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }

        movieWriter = writer
        captureWidth = pixelSize.width
        captureHeight = pixelSize.height
        self.stream = stream
        try await stream.startCapture()
        startHealthMonitor()
        RecordingDiagnostics.shared.log(
            "screen.start \(targetDescription) output=\(pixelSize.width)x\(pixelSize.height) "
                + "audio=\(audioSource.capturesSystemAudio) encoder=\(encoderConfiguration.encoder.displayName)"
        )
    }

    func stop() async throws {
        guard let stream, let movieWriter else { return }
        outputQueue.sync {
            isStopping = true
            healthTimer?.cancel()
            healthTimer = nil
        }
        var stopError: Error?
        do {
            try await stream.stopCapture()
        } catch {
            stopError = error
        }
        outputQueue.sync {}
        self.stream = nil
        self.movieWriter = nil

        do {
            try await movieWriter.finish(atSourceTime: latestScreenTimestamp)
        } catch {
            stopError = stopError ?? error
        }

        RecordingDiagnostics.shared.log(
            "screen.stop error=\((streamError ?? stopError)?.localizedDescription ?? "none")"
        )
        if let streamError { throw streamError }
        if let stopError { throw stopError }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .screen:
            let now = ProcessInfo.processInfo.systemUptime
            healthState?.recordScreenCallback(at: now)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if timestamp.isValid { latestScreenTimestamp = timestamp }

            guard let status = screenFrameStatus(sampleBuffer) else { return }
            if status != lastFrameStatus {
                lastFrameStatus = status
                RecordingDiagnostics.shared.log("screen.frame-status value=\(status.rawValue)")
            }
            guard status == .complete else { return }
            let accepted = movieWriter?.appendVideo(sampleBuffer) ?? false
            let waitingForSharedStart = startGate != nil && startGate?.startTime == nil
            healthState?.recordVideoAppend(accepted: accepted || waitingForSharedStart)
            reportHealthProblemIfNeeded(at: now)
        case .audio:
            movieWriter?.appendAudio(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        outputQueue.async { [weak self] in
            self?.reportFailure(error)
        }
    }

    private func startHealthMonitor() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            guard !isStopping else { return }
            let now = ProcessInfo.processInfo.systemUptime
            healthState = ScreenCaptureHealthState(startedAt: now)
            lastHealthLogAt = now
            let timer = DispatchSource.makeTimerSource(queue: outputQueue)
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
        if let healthState,
           time - (lastHealthLogAt ?? 0) >= 30 {
            lastHealthLogAt = time
            RecordingDiagnostics.shared.log(
                "screen.health callbackAge=\(String(format: "%.1f", time - healthState.lastScreenCallbackAt))s "
                    + "rejectedFrames=\(healthState.consecutiveRejectedFrames) "
                    + "frameStatus=\(lastFrameStatus?.rawValue.description ?? "none")"
            )
        }
        guard let problem = healthState?.problem(at: time) else { return }
        reportFailure(RecordItError.message(problem))
    }

    private func reportFailure(_ error: Error) {
        guard !isStopping, streamError == nil else { return }
        streamError = error
        healthTimer?.cancel()
        healthTimer = nil
        RecordingDiagnostics.shared.log("screen.failure error=\(error.localizedDescription)")
        emitTelemetry(at: ProcessInfo.processInfo.systemUptime, failureMessage: error.localizedDescription)
        onFailure?(error)
    }

    private func emitTelemetry(at time: TimeInterval, failureMessage: String? = nil) {
        guard let movieWriter else { return }
        let progress = movieWriter.progress()
        onTelemetry?(RecordingTelemetry(
            source: .screen,
            outputURL: outputURL,
            width: captureWidth,
            height: captureHeight,
            codecName: encoderConfiguration.encoder.codec.displayName,
            videoSamplesWritten: progress.videoSamplesWritten,
            audioSamplesWritten: progress.audioSamplesWritten,
            mediaDuration: progress.mediaDuration,
            fileSizeBytes: progress.fileSizeBytes,
            lastVideoActivityAt: healthState?.lastScreenCallbackAt,
            consecutiveRejectedVideoSamples: healthState?.consecutiveRejectedFrames ?? 0,
            writerStatus: progress.writerStatus,
            now: time,
            failureMessage: failureMessage
        ))
    }
}

private func screenFrameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard
        CMSampleBufferIsValid(sampleBuffer),
        CMSampleBufferDataIsReady(sampleBuffer),
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
        let statusValue = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: statusValue)
    else { return nil }

    return status
}
