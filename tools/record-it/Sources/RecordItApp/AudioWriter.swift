import AVFoundation

final class AudioWriter {
    private let outputURL: URL
    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private var sessionStartTime: CMTime?
    private var latestAudioTimestamp: CMTime?
    private var audioSamplesWritten = 0

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw RecordItError.message("AAC audio output could not be configured.")
        }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? RecordItError.message("The audio writer failed to start.")
        }
    }

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            CMSampleBufferDataIsReady(sampleBuffer),
            writer.status == .writing,
            audioInput.isReadyForMoreMediaData
        else { return false }

        let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartTime == nil {
            sessionStartTime = sourceTimestamp
            writer.startSession(atSourceTime: sourceTimestamp)
        }

        guard audioInput.append(sampleBuffer) else { return false }
        latestAudioTimestamp = sourceTimestamp + CMSampleBufferGetDuration(sampleBuffer)
        audioSamplesWritten += 1
        return true
    }

    func progress() -> WriterProgress {
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        return WriterProgress(
            videoSamplesWritten: 0,
            audioSamplesWritten: audioSamplesWritten,
            videoTimelineDuration: 0,
            audioTimelineDuration: timelineDuration,
            fileSizeBytes: size,
            writerStatus: recordingWriterStatus
        )
    }

    func finish() async throws {
        guard sessionStartTime != nil, audioSamplesWritten > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordItError.message("No audio samples were received.")
        }

        audioInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? RecordItError.message("The audio recording could not be finalized.")
        }
    }

    private var timelineDuration: TimeInterval {
        guard let sessionStartTime, let latestAudioTimestamp else { return 0 }
        return max(0, CMTimeGetSeconds(latestAudioTimestamp - sessionStartTime))
    }

    private var recordingWriterStatus: RecordingWriterStatus {
        switch writer.status {
        case .unknown: .unknown
        case .writing: .writing
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        @unknown default: .failed
        }
    }
}
