import AVFoundation
import Foundation

final class AudioWriter {
    private let outputURL: URL
    private var audioFile: AVAudioFile?
    private let inputFormat: AVAudioFormat
    private let processingFormat: AVAudioFormat
    private var converter: AVAudioConverter
    private var audioFramesWritten: AVAudioFramePosition = 0
    private var audioSamplesWritten = 0
    private var status: RecordingWriterStatus = .writing
    private(set) var latestPeakDecibels: Float = -160

    init(
        outputURL: URL,
        processingFormat: AVAudioFormat
    ) throws {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)

        guard processingFormat.sampleRate > 0, processingFormat.channelCount > 0 else {
            throw RecordItError.message("The selected input did not provide a usable audio format.")
        }
        inputFormat = processingFormat
        guard let canonicalFormat = AVAudioFormat(
            standardFormatWithSampleRate: processingFormat.sampleRate,
            channels: processingFormat.channelCount
        ), let converter = AVAudioConverter(from: processingFormat, to: canonicalFormat) else {
            throw RecordItError.message("The selected input could not be converted to standard PCM audio.")
        }
        self.processingFormat = canonicalFormat
        self.converter = converter

        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: audioOutputSettings(for: canonicalFormat),
                commonFormat: canonicalFormat.commonFormat,
                interleaved: canonicalFormat.isInterleaved
            )
        } catch {
            throw RecordItError.message(
                "AAC audio output could not be configured. \(detailedErrorDescription(error))"
            )
        }
    }

    @discardableResult
    func appendAudio(_ buffer: AVAudioPCMBuffer) throws -> Bool {
        guard status == .writing, buffer.frameLength > 0 else { return false }
        guard buffer.format.sampleRate == inputFormat.sampleRate,
              buffer.format.channelCount == inputFormat.channelCount else {
            status = .failed
            throw RecordItError.message("The selected input changed its audio format while recording.")
        }
        if converter.inputFormat != buffer.format {
            guard let matchingConverter = AVAudioConverter(
                from: buffer.format,
                to: processingFormat
            ) else {
                status = .failed
                throw RecordItError.message("The selected input's PCM layout could not be converted.")
            }
            converter = matchingConverter
        }
        let frameRatio = processingFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * frameRatio)
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: max(1, outputFrameCapacity)
        ) else {
            status = .failed
            throw RecordItError.message("A standard PCM audio buffer could not be allocated.")
        }
        do {
            try converter.convert(to: convertedBuffer, from: buffer)
        } catch {
            status = .failed
            throw RecordItError.message(
                "The selected input's PCM audio could not be converted. \(detailedErrorDescription(error))"
            )
        }
        guard convertedBuffer.frameLength > 0 else { return false }
        latestPeakDecibels = peakDecibels(in: convertedBuffer)

        do {
            guard let audioFile else {
                throw RecordItError.message("The audio output file is already closed.")
            }
            try audioFile.write(from: convertedBuffer)
        } catch {
            status = .failed
            throw RecordItError.message(
                "The AAC encoder rejected an audio sample. \(detailedErrorDescription(error))"
            )
        }

        audioFramesWritten += AVAudioFramePosition(convertedBuffer.frameLength)
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
        guard audioFramesWritten > 0, audioSamplesWritten > 0 else {
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
        guard processingFormat.sampleRate > 0 else { return 0 }
        return TimeInterval(audioFramesWritten) / processingFormat.sampleRate
    }

    private func closeAudioFile() {
        if #available(macOS 15.0, *) {
            audioFile?.close()
        }
        audioFile = nil
    }
}

func audioOutputSettings(for processingFormat: AVAudioFormat) -> [String: Any] {
    let channelCount = Int(processingFormat.channelCount)
    return [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: processingFormat.sampleRate,
        AVNumberOfChannelsKey: channelCount,
        AVEncoderBitRateKey: channelCount == 1 ? 96_000 : 128_000
    ]
}
