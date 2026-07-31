import AVFoundation
import CoreMedia
import Foundation

final class AudioWriter {
    private let outputURL: URL
    private var audioFile: AVAudioFile?
    private let processingFormat: AVAudioFormat
    private var sessionStartTime: CMTime?
    private var latestAudioTimestamp: CMTime?
    private var audioSamplesWritten = 0
    private var status: RecordingWriterStatus = .writing

    init(
        outputURL: URL,
        sourceFormatHint: CMAudioFormatDescription
    ) throws {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)

        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: sourceFormatHint)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw RecordItError.message("The selected input did not provide a usable audio format.")
        }
        processingFormat = sourceFormat
        let channelCount = Int(sourceFormat.channelCount)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: channelCount == 1 ? 96_000 : 192_000
        ]

        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: sourceFormat.commonFormat,
                interleaved: sourceFormat.isInterleaved
            )
        } catch {
            throw RecordItError.message(
                "AAC audio output could not be configured. \(detailedErrorDescription(error))"
            )
        }
    }

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        guard CMSampleBufferDataIsReady(sampleBuffer), status == .writing else { return false }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return false }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: frameCount
        ) else {
            throw RecordItError.message("An audio buffer could not be allocated.")
        }
        buffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            status = .failed
            throw RecordItError.message(
                "Audio samples could not be copied from the selected input. "
                    + "Core Media returned OSStatus \(copyStatus)."
            )
        }

        do {
            guard let audioFile else {
                throw RecordItError.message("The audio output file is already closed.")
            }
            try audioFile.write(from: buffer)
        } catch {
            status = .failed
            throw RecordItError.message(
                "The AAC encoder rejected an audio sample. \(detailedErrorDescription(error))"
            )
        }

        let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartTime == nil {
            sessionStartTime = sourceTimestamp
        }
        let timeScale = CMTimeScale(processingFormat.sampleRate.rounded())
        latestAudioTimestamp = sourceTimestamp
            + CMTime(value: CMTimeValue(frameCount), timescale: timeScale)
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
            writerStatus: status
        )
    }

    func finish() async throws {
        guard sessionStartTime != nil, audioSamplesWritten > 0 else {
            status = .cancelled
            closeAudioFile()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordItError.message("No audio samples were received.")
        }
        guard status == .writing else {
            throw RecordItError.message("The AAC encoder stopped before the recording could be finalized.")
        }

        closeAudioFile()
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard size > 0 else {
            status = .failed
            throw RecordItError.message("The audio recording finalized as an empty file.")
        }
        status = .completed
    }

    private var timelineDuration: TimeInterval {
        guard let sessionStartTime, let latestAudioTimestamp else { return 0 }
        return max(0, CMTimeGetSeconds(latestAudioTimestamp - sessionStartTime))
    }

    private func closeAudioFile() {
        if #available(macOS 15.0, *) {
            audioFile?.close()
        }
        audioFile = nil
    }
}
