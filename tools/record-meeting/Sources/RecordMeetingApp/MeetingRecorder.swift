import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class MeetingRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var finishResult: Result<Void, Error>?
    private var streamError: Error?

    func start(outputURL: URL) async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecordMeetingError.message(
                "Screen & System Audio Recording access is required. Enable Record Meeting in Privacy & Security, then reopen it."
            )
        }
        guard await requestMicrophoneAccess() else {
            throw RecordMeetingError.message(
                "Microphone access is required. Enable Record Meeting in Privacy & Security → Microphone."
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw RecordMeetingError.message("No display is available for system-audio capture.")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        // SCRecordingOutput needs a video stream, but Record Meeting discards it
        // after extracting the audio. Keep it tiny and infrequent.
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = outputURL
        outputConfiguration.outputFileType = .mov
        outputConfiguration.videoCodecType = .h264

        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)

        lock.withLock {
            finishContinuation = nil
            finishResult = nil
            streamError = nil
            self.stream = stream
            recordingOutput = output
        }

        do {
            try await stream.startCapture()
        } catch {
            clearState()
            throw error
        }
    }

    func stop() async throws {
        let activeStream = lock.withLock { stream }
        guard let activeStream else { return }

        var stopError: Error?
        do {
            try await activeStream.stopCapture()
        } catch {
            stopError = error
        }

        do {
            try await waitForRecordingToFinish()
        } catch {
            stopError = stopError ?? error
        }

        let capturedStreamError = lock.withLock { streamError }
        clearState()

        if let capturedStreamError { throw capturedStreamError }
        if let stopError { throw stopError }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            streamError = error
        }
        finish(.failure(error))
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finish(.success(()))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        finish(.failure(error))
    }

    private func waitForRecordingToFinish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            var immediateResult: Result<Void, Error>?
            lock.withLock {
                if let finishResult {
                    immediateResult = finishResult
                } else {
                    finishContinuation = continuation
                }
            }
            if let result = immediateResult {
                continuation.resume(with: result)
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard finishResult == nil else { return nil }
            finishResult = result
            let continuation = finishContinuation
            finishContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func clearState() {
        lock.withLock {
            stream = nil
            recordingOutput = nil
            finishContinuation = nil
            finishResult = nil
            streamError = nil
        }
    }
}

private func requestMicrophoneAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}
