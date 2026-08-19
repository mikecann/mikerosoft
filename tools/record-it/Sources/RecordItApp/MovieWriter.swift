import AVFoundation
import VideoToolbox

func videoOutputSettings(
    width: Int,
    height: Int,
    configuration: EncoderConfiguration
) -> [String: Any] {
    let bitRate = max(1, configuration.bitRateMbps) * 1_000_000
    let maximumBitRate = max(configuration.bitRateMbps, configuration.maximumBitRateMbps) * 1_000_000
    var compressionProperties: [String: Any] = [
        AVVideoExpectedSourceFrameRateKey: 30,
        AVVideoMaxKeyFrameIntervalKey: 60,
        kVTCompressionPropertyKey_RealTime as String: true
    ]

    switch configuration.rateControl {
    case .cbr:
        compressionProperties[kVTCompressionPropertyKey_ConstantBitRate as String] = bitRate
    case .cqp:
        // AVAssetWriter does not expose per-frame QP options, so pin both hardware
        // encoder bounds to the same value to produce constant-QP output.
        let qualityParameter = min(51, max(0, configuration.qualityParameter))
        compressionProperties[kVTCompressionPropertyKey_MinAllowedFrameQP as String] = qualityParameter
        compressionProperties[kVTCompressionPropertyKey_MaxAllowedFrameQP as String] = qualityParameter
    case .vbr:
        if #available(macOS 26.0, *) {
            compressionProperties[kVTCompressionPropertyKey_VariableBitRate as String] = bitRate
            compressionProperties[kVTCompressionPropertyKey_VBVMaxBitRate as String] = maximumBitRate
        } else {
            compressionProperties[kVTCompressionPropertyKey_AverageBitRate as String] = bitRate
            compressionProperties[kVTCompressionPropertyKey_DataRateLimits as String] = [
                maximumBitRate / 8,
                1
            ]
        }
    }

    return [
        AVVideoCodecKey: configuration.encoder.codec.avVideoCodecType,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoEncoderSpecificationKey: [
            kVTVideoEncoderSpecification_EncoderID as String: configuration.encoder.id
        ],
        AVVideoCompressionPropertiesKey: compressionProperties
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
    private var pendingVideoSample: CMSampleBuffer?
    private var pendingVideoFrameIndex: Int?
    private var lastOutputFrameIndex = -1
    private var latestAudioTimestamp: CMTime?
    private var latestVideoEndTime: CMTime?
    private var videoSamplesWritten = 0
    private var audioSamplesWritten = 0

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        includesAudio: Bool,
        encoderConfiguration: EncoderConfiguration,
        startGate: RecordingStartGate? = nil
    ) throws {
        self.outputURL = outputURL
        self.startGate = startGate
        try? FileManager.default.removeItem(at: outputURL)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings(
                width: width,
                height: height,
                configuration: encoderConfiguration
            )
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordItError.message("The selected hardware video encoder could not be configured.")
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

    @discardableResult
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferDataIsReady(sampleBuffer), writer.status == .writing else { return false }
        let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartTime == nil {
            if let startGate {
                guard let gatedStartTime = startGate.startTime, sourceTimestamp >= gatedStartTime else {
                    return false
                }
                sessionStartTime = gatedStartTime
                writer.startSession(atSourceTime: gatedStartTime)
            } else {
                sessionStartTime = sourceTimestamp
                writer.startSession(atSourceTime: sourceTimestamp)
            }
        }
        guard let sessionStartTime else { return false }

        let elapsed = max(0, CMTimeGetSeconds(sourceTimestamp - sessionStartTime))
        let targetFrameIndex = max(0, Int((elapsed * 30).rounded()))
        if let pendingVideoFrameIndex, targetFrameIndex <= pendingVideoFrameIndex {
            // Keep the newest pixels when ScreenCaptureKit produces more than
            // one sample for the same 30 fps presentation slot.
            pendingVideoSample = sampleBuffer
            return true
        }

        if let pendingVideoSample, let pendingVideoFrameIndex {
            let durationInFrames = max(1, targetFrameIndex - pendingVideoFrameIndex)
            guard appendRetimedVideo(
                pendingVideoSample,
                frameIndex: pendingVideoFrameIndex,
                durationInFrames: durationInFrames
            ) else {
                return false
            }
        }

        // Hold one frame until the next source update tells us its real
        // duration. This represents static screen time with one long sample
        // instead of trying to encode thousands of duplicate 4K frames.
        pendingVideoSample = sampleBuffer
        pendingVideoFrameIndex = targetFrameIndex
        return true
    }

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard
            CMSampleBufferDataIsReady(sampleBuffer),
            writer.status == .writing,
            let sessionStartTime,
            let audioInput,
            audioInput.isReadyForMoreMediaData,
            sourceTimestamp >= sessionStartTime
        else { return false }

        if audioInput.append(sampleBuffer) {
            latestAudioTimestamp = sourceTimestamp + CMSampleBufferGetDuration(sampleBuffer)
            audioSamplesWritten += 1
            return true
        }
        return false
    }

    func progress() -> WriterProgress {
        let videoDuration = timelineDuration(through: latestVideoEndTime)
        let audioDuration = timelineDuration(through: latestAudioTimestamp)
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        return WriterProgress(
            videoSamplesWritten: videoSamplesWritten,
            audioSamplesWritten: audioSamplesWritten,
            videoTimelineDuration: videoDuration,
            audioTimelineDuration: audioDuration,
            fileSizeBytes: size,
            writerStatus: recordingWriterStatus
        )
    }

    func finish(atSourceTime requestedEndTime: CMTime? = nil) async throws {
        guard let pendingVideoSample, let pendingVideoFrameIndex, let sessionStartTime else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordItError.message("No video frames were received.")
        }

        let minimumEndTime = sessionStartTime
            + CMTime(value: CMTimeValue(pendingVideoFrameIndex + 1), timescale: 30)
        let endTime = [requestedEndTime, latestAudioTimestamp]
            .compactMap { $0 }
            .filter(\.isValid)
            .reduce(minimumEndTime) { max($0, $1) }
        let endFrameIndex = max(
            pendingVideoFrameIndex + 1,
            Int(ceil(max(0, CMTimeGetSeconds(endTime - sessionStartTime)) * 30))
        )

        try await waitForVideoInputReadiness()
        guard appendRetimedVideo(
            pendingVideoSample,
            frameIndex: pendingVideoFrameIndex,
            durationInFrames: endFrameIndex - pendingVideoFrameIndex
        ) else {
            throw writer.error ?? RecordItError.message("The final video frame could not be written.")
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

    private func waitForVideoInputReadiness() async throws {
        for _ in 0..<500 {
            if videoInput.isReadyForMoreMediaData { return }
            guard writer.status == .writing else {
                throw writer.error ?? RecordItError.message("The video encoder stopped accepting frames.")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RecordItError.message("The video encoder remained stalled for more than five seconds.")
    }

    private func appendRetimedVideo(
        _ sampleBuffer: CMSampleBuffer,
        frameIndex: Int,
        durationInFrames: Int
    ) -> Bool {
        guard videoInput.isReadyForMoreMediaData, let sessionStartTime else { return false }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(max(1, durationInFrames)), timescale: 30),
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
        latestVideoEndTime = timing.presentationTimeStamp + timing.duration
        videoSamplesWritten += 1
        return true
    }

    private func timelineDuration(through timestamp: CMTime?) -> TimeInterval {
        guard let timestamp, let sessionStartTime else { return 0 }
        return max(0, CMTimeGetSeconds(timestamp - sessionStartTime))
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
