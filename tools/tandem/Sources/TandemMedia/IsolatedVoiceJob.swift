import AudioToolbox
import AVFoundation
import Foundation
import TandemCore

/// The voice with the room removed: Apple's AUSoundIsolation run offline
/// over the whole file at 48 kHz, written as lossless ALAC in `voice.caf`.
///
/// The unit delays its output (3,665 samples for the voice model), so the
/// first `latency` rendered samples are dropped and `latency` samples of
/// silence are fed after the end: sample n of the result lines up with
/// sample n of the original, and both files are the same length. Silence is
/// added in front when the source's audio starts after zero, so the result
/// always starts at media time zero.
enum IsolatedVoiceJob {
    static let file = "voice.caf"
    static let sampleRate = 48_000.0
    static let chunk: AVAudioFrameCount = 4096

    /// Measured latency of each model at 48 kHz, used when the unit reports 0.
    static func knownLatency(_ model: VoiceIsolationModel) -> Int {
        switch model {
        case .voice: return 3665
        case .highQualityVoice: return 6360
        }
    }

    struct Output: Equatable {
        var frames: Int
        var latency: Int
        var channels: Int
    }

    static func run(source: URL, model: VoiceIsolationModel, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws {
        _ = try await render(source: source, model: model, to: folder.appendingPathComponent(file), context: context, timeRange: timeRange)
    }

    @discardableResult
    static func render(source: URL, model: VoiceIsolationModel, to url: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws -> Output {
        let probe = try await AudioReader(url: source, timeRange: timeRange)
        let channels = min(2, probe.channels)
        probe.cancel()
        let reader = try await AudioReader(url: source, sampleRate: sampleRate, channels: channels, timeRange: timeRange)
        return try await Blocking.run(qos: context.qos) {
            try renderOffline(reader: reader, channels: channels, model: model, to: url, context: context, rangeStart: timeRange?.start.seconds ?? 0)
        }
    }

    static func renderOffline(reader: AudioReader, channels: Int, model: VoiceIsolationModel, to url: URL, context: JobContext, rangeStart: Double) throws -> Output {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            throw MediaError.failed("Unsupported channel count \(channels)")
        }
        let feed = PlanarFeed(reader: reader, channels: channels, rangeStart: rangeStart)

        let engine = AVAudioEngine()
        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            feed.fill(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(frameCount))
            return noErr
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &description) != nil else {
            throw MediaError.notApplicable("This Mac has no AUSoundIsolation")
        }
        let isolation = AVAudioUnitEffect(audioComponentDescription: description)
        engine.attach(sourceNode)
        engine.attach(isolation)
        engine.connect(sourceNode, to: isolation, format: format)
        engine.connect(isolation, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        let modelValue: AudioUnitParameterValue = model == .voice ? AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice) : AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice)
        AudioUnitSetParameter(isolation.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate), kAudioUnitScope_Global, 0, modelValue, 0)
        AudioUnitSetParameter(isolation.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent), kAudioUnitScope_Global, 0, 100, 0)
        try engine.start()
        defer { engine.stop() }

        // The unit only reports its latency once running.
        let reported = Int((isolation.auAudioUnit.latency * sampleRate).rounded())
        let latency = reported > 0 ? reported : knownLatency(model)

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 16
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount),
              let tail = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw MediaError.failed("Out of memory for voice isolation") }

        var rendered = 0
        var written = 0
        var chunks = 0
        while true {
            // Once the input has run out its length is known: render until
            // the delayed output has caught up with it.
            let target = feed.inputFrames.map { $0 + latency }
            if let target, rendered >= target { break }
            let count = min(Int(buffer.frameCapacity), target.map { $0 - rendered } ?? Int(buffer.frameCapacity))
            let status = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            switch status {
            case .success:
                break
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw MediaError.failed("Voice isolation failed while rendering")
            @unknown default:
                throw MediaError.failed("Voice isolation stopped unexpectedly")
            }
            let frames = Int(buffer.frameLength)
            let skip = max(0, min(frames, latency - rendered))
            rendered += frames
            if frames > skip {
                if skip == 0 {
                    try file.write(from: buffer)
                } else {
                    tail.frameLength = AVAudioFrameCount(frames - skip)
                    for channel in 0..<channels {
                        tail.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + skip, count: frames - skip)
                    }
                    try file.write(from: tail)
                }
                written += frames - skip
            }
            chunks += 1
            if chunks % 32 == 0 {
                try context.checkCancellation()
                if reader.duration > 0 { context.progress(Double(written) / (reader.duration * sampleRate)) }
            }
            if let error = feed.error { throw error }
        }
        // Resampling can come up a few samples short at the very end; pad so
        // the result is exactly as long as the source.
        let expected = Int((reader.duration * sampleRate).rounded())
        if written < expected, expected - written < Int(sampleRate) {
            tail.frameLength = AVAudioFrameCount(min(Int(tail.frameCapacity), expected - written))
            while written < expected {
                let count = min(Int(tail.frameCapacity), expected - written)
                tail.frameLength = AVAudioFrameCount(count)
                for channel in 0..<channels { tail.floatChannelData![channel].update(repeating: 0, count: count) }
                try file.write(from: tail)
                written += count
            }
        }
        return Output(frames: written, latency: latency, channels: channels)
    }

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(file) }
}

/// Supplies the render thread with the source's samples, deinterleaved,
/// starting at media time zero; silence once the file runs out.
final class PlanarFeed: @unchecked Sendable {
    private let reader: AudioReader
    private let channels: Int
    private var queue: [Float] = []
    private var queueOffset = 0
    private var leadingSilence: Int?
    private let rangeStart: Double
    private var supplied = 0
    private var exhausted = false
    /// Frames the source had (including leading silence), known once read.
    private(set) var inputFrames: Int?
    private(set) var error: Error?

    init(reader: AudioReader, channels: Int, rangeStart: Double) {
        self.reader = reader
        self.channels = channels
        self.rangeStart = rangeStart
    }

    func fill(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        var filled = 0
        while filled < frames {
            // Keep reading until there's audio or the file is done; silence
            // mid-stream would shift everything after it.
            while queue.count - queueOffset < channels, !exhausted { pull() }
            let available = (queue.count - queueOffset) / channels
            if available == 0 {
                // Out of source: silence, which pushes the unit's delayed tail out.
                for channel in 0..<min(channels, buffers.count) {
                    let destination = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                    (destination + filled).update(repeating: 0, count: frames - filled)
                }
                if exhausted, inputFrames == nil { inputFrames = supplied }
                return
            }
            let count = min(available, frames - filled)
            queue.withUnsafeBufferPointer { samples in
                for channel in 0..<min(channels, buffers.count) {
                    let destination = buffers[channel].mData!.assumingMemoryBound(to: Float.self) + filled
                    for i in 0..<count { destination[i] = samples[queueOffset + i * channels + channel] }
                }
            }
            queueOffset += count * channels
            filled += count
            supplied += count
        }
        if queueOffset > 1 << 16 {
            queue.removeFirst(queueOffset)
            queueOffset = 0
        }
    }

    private func pull() {
        do {
            let more = try reader.next { samples, _, start in
                if leadingSilence == nil {
                    // Line the result up with media time zero.
                    let silence = max(0, Int(((start.seconds - rangeStart) * reader.sampleRate).rounded()))
                    leadingSilence = silence
                    queue.append(contentsOf: repeatElement(0, count: silence * channels))
                }
                queue.append(contentsOf: samples)
            }
            if !more { exhausted = true }
        } catch {
            self.error = error
            exhausted = true
        }
    }
}
