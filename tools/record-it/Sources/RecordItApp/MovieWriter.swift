import AVFoundation

func videoOutputSettings(width: Int, height: Int) -> [String: Any] {
    let pixels = width * height
    let bitRate = pixels >= 3840 * 2160 ? 60_000_000 : 30_000_000
    return [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 60
        ]
    ]
}

enum RecordItError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

final class MovieWriter {
    private let outputURL: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let startGate: RecordingStartGate?
    private var sessionStartTime: CMTime?
    private var receivedVideo = false
    private var lastVideoSample: CMSampleBuffer?
    private var lastOutputFrameIndex = -1
    private let frameDuration = CMTime(value: 1, timescale: 30)

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        includesAudio: Bool,
        startGate: RecordingStartGate? = nil
    ) throws {
        self.outputURL = outputURL
        self.startGate = startGate
        try? FileManager.default.removeItem(at: outputURL)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings(width: width, height: height)
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordItError.message("The HEVC video writer could not be configured.")
        }
        writer.add(videoInput)

        if includesAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecordItError.message("The movie writer failed to start.")
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer), writer.status == .writing else { return }
        let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartTime == nil {
            if let startGate {
                guard let gatedStartTime = startGate.startTime, sourceTimestamp >= gatedStartTime else {
                    return
                }
                sessionStartTime = gatedStartTime
                writer.startSession(atSourceTime: gatedStartTime)
            } else {
                sessionStartTime = sourceTimestamp
                writer.startSession(atSourceTime: sourceTimestamp)
            }
        }
        guard let sessionStartTime else { return }

        let elapsed = max(0, CMTimeGetSeconds(sourceTimestamp - sessionStartTime))
        let targetFrameIndex = lastOutputFrameIndex < 0
            ? 0
            : max(0, Int((elapsed * 30).rounded()))
        guard targetFrameIndex > lastOutputFrameIndex else {
            lastVideoSample = sampleBuffer
            return
        }

        while lastOutputFrameIndex + 1 < targetFrameIndex, let lastVideoSample {
            guard appendRetimedVideo(lastVideoSample, frameIndex: lastOutputFrameIndex + 1) else {
                return
            }
        }

        guard lastOutputFrameIndex + 1 == targetFrameIndex else { return }
        if appendRetimedVideo(sampleBuffer, frameIndex: targetFrameIndex) {
            lastVideoSample = sampleBuffer
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard
            CMSampleBufferDataIsReady(sampleBuffer),
            writer.status == .writing,
            let sessionStartTime,
            let audioInput,
            audioInput.isReadyForMoreMediaData,
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= sessionStartTime
        else { return }

        audioInput.append(sampleBuffer)
    }

    func finish() async throws {
        guard receivedVideo else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordItError.message("No video frames were received.")
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? RecordItError.message("The recording could not be finalized.")
        }
    }

    private func appendRetimedVideo(_ sampleBuffer: CMSampleBuffer, frameIndex: Int) -> Bool {
        guard videoInput.isReadyForMoreMediaData, let sessionStartTime else { return false }
        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: sessionStartTime + CMTime(value: CMTimeValue(frameIndex), timescale: 30),
            decodeTimeStamp: .invalid
        )
        var retimedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimedBuffer
        )
        guard status == noErr, let retimedBuffer, videoInput.append(retimedBuffer) else {
            return false
        }

        lastOutputFrameIndex = frameIndex
        receivedVideo = true
        return true
    }
}
