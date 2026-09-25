import AVFoundation
import Foundation
import TandemMedia

/// What the audio pass found.
struct AudioAnalysis: Sendable {
    var duration: Double
    var channels: Int
    var loudness: Loudness
    var waveform: Waveform
    /// False when the original is used as it is and nothing was written.
    var wroteOutput: Bool
}

/// Decodes audio, resamples it to 48 kHz and writes 24-bit PCM WAV,
/// measuring loudness (EBU R128 via `LoudnessMeter`) and waveform peaks in
/// the same pass.
///
/// Two kinds of file are measured but not rewritten: 48 kHz PCM already in
/// WAV, AIFF or CAF (a copy would change nothing), and anything longer than
/// `longestRewrite` that AVFoundation can play (a two hour stock bed would
/// be a 2 GB WAV).
enum AudioNormaliser {
    static let sampleRate = 48_000.0
    /// Peaks a second in `peaks.bin`: fine enough for a short click, small
    /// enough for a long bed (3 minutes is 72 KB).
    static let peaksPerSecond = 100
    /// Seconds; longer files are measured but kept as they are.
    static let longestRewrite = 20.0 * 60

    /// Whether `input` can be used as it is, going by its format and length.
    static func canUseAsIs(_ input: URL, format: AssetFormat) -> Bool {
        guard let file = try? AVAudioFile(forReading: input) else { return false }
        let description = file.fileFormat.streamDescription.pointee
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        let isPCM = description.mFormatID == kAudioFormatLinearPCM
        if isPCM && file.fileFormat.sampleRate == sampleRate && [.wav, .aiff, .caf].contains(format) && file.fileFormat.channelCount <= 2 {
            return true
        }
        return seconds > longestRewrite
    }

    /// Measures `input` and, when `output` is given, writes the 48 kHz copy.
    static func normalise(input: URL, output: URL?, ffmpeg: FFmpeg?) throws -> AudioAnalysis {
        do {
            return try convert(input: input, output: output)
        } catch {
            // AVFoundation can't decode Ogg Vorbis or Opus (it may open the
            // file and then fail to read it); ffmpeg can.
            guard let ffmpeg, let output else {
                if let error = error as? AssetError { throw error }
                throw AssetError.normaliseFailed("can't decode \(input.lastPathComponent): \(error.localizedDescription)")
            }
            let temporary = output.deletingLastPathComponent().appendingPathComponent("decoded-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try ffmpeg.run(["-y", "-v", "error", "-i", input.path, "-vn", "-ar", "48000", "-c:a", "pcm_f32le", temporary.path])
            return try convert(input: temporary, output: output)
        }
    }

    private static func convert(input: URL, output: URL?) throws -> AudioAnalysis {
        let source = try AVAudioFile(forReading: input)
        let inFormat = source.processingFormat
        let channels = AVAudioChannelCount(min(Int(inFormat.channelCount), 2))
        guard channels > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AssetError.normaliseFailed("unsupported audio format in \(input.lastPathComponent)")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        if inFormat.channelCount > 2 { converter.downmix = true }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        var sink: AVAudioFile?
        if let output {
            try? FileManager.default.removeItem(at: output)
            sink = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        var meter = LoudnessMeter(sampleRate: sampleRate, channels: Int(channels))
        var peaks = PeakAccumulator(bucketLength: Int(sampleRate) / peaksPerSecond)
        let inCapacity: AVAudioFrameCount = 16_384
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(inCapacity) * sampleRate / inFormat.sampleRate) + 4_096) else {
            throw AssetError.normaliseFailed("can't allocate audio buffers")
        }

        var reachedEnd = false
        var readFailure: Error?
        var frames: Int64 = 0
        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if reachedEnd || source.framePosition >= source.length {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try source.read(into: inBuffer, frameCount: inCapacity)
                } catch {
                    readFailure = error
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let readFailure { throw AssetError.normaliseFailed("reading \(input.lastPathComponent): \(readFailure.localizedDescription)") }
            if status == .error {
                throw AssetError.normaliseFailed("converting \(input.lastPathComponent): \(conversionError?.localizedDescription ?? "unknown error")")
            }
            let count = Int(outBuffer.frameLength)
            if count > 0, let data = outBuffer.floatChannelData {
                try sink?.write(from: outBuffer)
                let planes = (0..<Int(channels)).map { UnsafeBufferPointer(start: data[$0], count: count) }
                meter.process(planar: planes)
                peaks.add(planes: planes)
                frames += Int64(count)
            }
            if status == .endOfStream || (status == .inputRanDry && reachedEnd && count == 0) { break }
        }
        return AudioAnalysis(
            duration: Double(frames) / sampleRate,
            channels: Int(channels),
            loudness: meter.result(),
            waveform: Waveform(samplesPerSecond: peaksPerSecond, peaks: peaks.finish()),
            wroteOutput: sink != nil
        )
    }

    /// Writes peaks as little-endian Float32.
    static func writePeaks(_ waveform: Waveform, to url: URL) throws {
        var data = Data(capacity: waveform.peaks.count * 4)
        for peak in waveform.peaks {
            var bits = peak.bitPattern.littleEndian
            data.append(Data(bytes: &bits, count: 4))
        }
        try data.write(to: url, options: .atomic)
    }

    /// Reads peaks written by `writePeaks`.
    static func readPeaks(from url: URL, samplesPerSecond: Int = peaksPerSecond) throws -> Waveform {
        let data = try Data(contentsOf: url)
        var peaks: [Float] = []
        peaks.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count - 3, by: 4) {
                let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                peaks.append(Float(bitPattern: UInt32(littleEndian: bits)))
            }
        }
        return Waveform(samplesPerSecond: samplesPerSecond, peaks: peaks)
    }
}

/// Absolute peak per bucket of frames, across channels.
struct PeakAccumulator {
    let bucketLength: Int
    private var current: Float = 0
    private var filled = 0
    private var peaks: [Float] = []

    init(bucketLength: Int) {
        self.bucketLength = max(1, bucketLength)
    }

    mutating func add(planes: [UnsafeBufferPointer<Float>]) {
        let frames = planes.map(\.count).min() ?? 0
        for frame in 0..<frames {
            for plane in planes {
                current = max(current, abs(plane[frame]))
            }
            filled += 1
            if filled == bucketLength {
                peaks.append(min(current, 1))
                current = 0
                filled = 0
            }
        }
    }

    mutating func finish() -> [Float] {
        if filled > 0 {
            peaks.append(min(current, 1))
            current = 0
            filled = 0
        }
        return peaks
    }
}
