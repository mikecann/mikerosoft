import AVFoundation
import CoreMedia
import Foundation
import TandemCore

/// Runs blocking work (reader loops, Vision, encoders) on a GCD queue so it
/// never ties up Swift's cooperative threads.
enum Blocking {
    static func run<T>(qos: DispatchQoS.QoSClass = .utility, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

extension Time {
    /// Snapped to the 48 kHz grid like every stored Time, so values survive
    /// a JSON round trip unchanged.
    init(_ time: CMTime) {
        self.init(seconds: time.seconds)
    }
}

extension CMTime {
    init(_ time: Time) {
        self = CMTime(value: time.flicks, timescale: CMTimeScale(Time.flicksPerSecond))
    }
}

/// JSON for cache files: sorted keys, and loudness of silence (-infinity)
/// kept as a string instead of failing to encode.
enum CacheJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

/// A size that fits inside a box, keeping the aspect ratio, never larger
/// than the source, with even sides for the video encoders. Portrait sources
/// use the box turned on its side.
func fittedSize(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { return (2, 2) }
    let (boxWidth, boxHeight) = height > width ? (maxHeight, maxWidth) : (maxWidth, maxHeight)
    let scale = min(1, Double(boxWidth) / Double(width), Double(boxHeight) / Double(height))
    func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
    return (even(Double(width) * scale), even(Double(height) * scale))
}

/// Reads an asset's first audio track as interleaved 32-bit float PCM, in
/// chunks, with each chunk's position in media time.
final class AudioReader: @unchecked Sendable {
    let sampleRate: Double
    let channels: Int
    /// Seconds of media to read: the asset's, or the time range's.
    let duration: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    /// - Parameters:
    ///   - sampleRate: resample to this rate; nil keeps the file's.
    ///   - channels: mix to this many channels; nil keeps the file's.
    ///   - timeRange: read only part of the file.
    init(url: URL, sampleRate: Double? = nil, channels: Int? = nil, timeRange: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (tracks, duration) = try await asset.load(.tracks, .duration)
        guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
            throw MediaError.notApplicable("\(url.lastPathComponent) has no audio")
        }
        let formats = try await track.load(.formatDescriptions)
        let native = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = sampleRate ?? native.map { Double($0.mSampleRate) } ?? 48_000
        let count = channels ?? Int(native?.mChannelsPerFrame ?? 2)
        self.sampleRate = rate
        self.channels = max(1, count)
        self.duration = timeRange.map { $0.duration.seconds } ?? duration.seconds

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: self.channels
        ]
        // Changing the channel count needs a layout to mix to.
        if let layout = Self.layout(for: self.channels), channels != nil {
            settings[AVChannelLayoutKey] = layout
        }
        reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.failed("Can't read the audio of \(url.lastPathComponent)") }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.unreadable(url.lastPathComponent, reader.error?.localizedDescription ?? "the audio can't be decoded")
        }
    }

    private static func layout(for channels: Int) -> Data? {
        let tag: AudioChannelLayoutTag
        switch channels {
        case 1: tag = kAudioChannelLayoutTag_Mono
        case 2: tag = kAudioChannelLayoutTag_Stereo
        default: return nil
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// Calls `body` with the next chunk of samples (`frames * channels`
    /// values) and its start in media time, or returns false at the end.
    func next(_ body: (UnsafeBufferPointer<Float>, _ frames: Int, _ start: CMTime) throws -> Void) throws -> Bool {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw MediaError.failed("Audio decoding failed: \(reader.error?.localizedDescription ?? "unknown error")")
            }
            return false
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return true }
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        var contiguous = block
        if !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) {
            var copy: CMBlockBuffer?
            CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &copy)
            guard let copy else { return true }
            contiguous = copy
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return true }
        let values = min(frames * channels, length / MemoryLayout<Float>.size)
        try pointer.withMemoryRebound(to: Float.self, capacity: values) { floats in
            try body(UnsafeBufferPointer(start: floats, count: values), values / channels, start)
        }
        return true
    }

    func cancel() {
        reader.cancelReading()
    }
}
