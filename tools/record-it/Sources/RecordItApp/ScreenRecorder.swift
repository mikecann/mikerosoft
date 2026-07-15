import AVFoundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let display: CaptureDisplay
    private let audioSource: ScreenAudioSource
    private let outputURL: URL
    private let startGate: RecordingStartGate?
    private let outputQueue = DispatchQueue(label: "com.mikerosoft.record-it.screen-output")
    private var stream: SCStream?
    private var movieWriter: MovieWriter?
    private var streamError: Error?

    init(
        display: CaptureDisplay,
        audioSource: ScreenAudioSource,
        outputURL: URL,
        startGate: RecordingStartGate? = nil
    ) {
        self.display = display
        self.audioSource = audioSource
        self.outputURL = outputURL
        self.startGate = startGate
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecordItError.message(
                "Screen Recording access is required. Enable Record It in Privacy & Security → Screen & System Audio Recording, then relaunch the app."
            )
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw RecordItError.message("The selected display is no longer available.")
        }

        let writer = try MovieWriter(
            outputURL: outputURL,
            width: display.width,
            height: display.height,
            includesAudio: audioSource.capturesSystemAudio,
            startGate: startGate
        )
        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
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
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws {
        guard let stream, let movieWriter else { return }
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
            try await movieWriter.finish()
        } catch {
            stopError = stopError ?? error
        }

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
            guard isCompleteScreenFrame(sampleBuffer) else { return }
            movieWriter?.appendVideo(sampleBuffer)
        case .audio:
            movieWriter?.appendAudio(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
    }
}

private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
        CMSampleBufferIsValid(sampleBuffer),
        CMSampleBufferDataIsReady(sampleBuffer),
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
        let statusValue = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: statusValue)
    else { return false }

    return status == .complete
}
