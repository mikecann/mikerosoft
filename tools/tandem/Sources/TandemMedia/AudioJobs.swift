import Accelerate
import AVFoundation
import Foundation
import TandemCore

/// Mono peak envelope for drawing audio: the loudest absolute sample over
/// all channels, `rate` times a second of media.
///
/// Stored as `waveform.json` (a small header) beside `peaks.f32` (raw
/// little-endian Float32 peaks), so drawing a 24 minute take reads 580 KB
/// without parsing JSON numbers.
enum WaveformJob {
    static let headerFile = "waveform.json"
    static let peaksFile = "peaks.f32"

    struct Header: Codable, Equatable {
        var version = 1
        var samplesPerSecond: Int
        var count: Int
        var format = "float32le"
        var file = WaveformJob.peaksFile
        var sourceSampleRate: Double
        var sourceChannels: Int
    }

    static func run(source: URL, rate: Int, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws {
        let reader = try await AudioReader(url: source, timeRange: timeRange)
        let peaks = try await Blocking.run(qos: context.qos) {
            try measure(reader, rate: rate, rangeStart: timeRange?.start.seconds ?? 0, context: context)
        }
        try write(Waveform(samplesPerSecond: rate, peaks: peaks), sourceRate: reader.sampleRate, channels: reader.channels, into: folder)
    }

    static func measure(_ reader: AudioReader, rate: Int, rangeStart: Double, context: JobContext) throws -> [Float] {
        let bucket = max(1, Int((reader.sampleRate / Double(rate)).rounded()))
        let expected = Int((reader.duration * Double(rate)).rounded(.up))
        var peaks = [Float](repeating: 0, count: max(0, expected))
        let channels = reader.channels
        var chunks = 0
        while try reader.next({ samples, frames, start in
            // Place each chunk by its time stamp, so leading silence or a
            // late-starting audio track still lines up with media time.
            var position = Int(((start.seconds - rangeStart) * reader.sampleRate).rounded())
            var offset = 0
            while offset < frames {
                let index = max(0, position) / bucket
                let count = min(frames - offset, bucket - max(0, position) % bucket)
                var peak: Float = 0
                vDSP_maxmgv(samples.baseAddress! + offset * channels, 1, &peak, vDSP_Length(count * channels))
                if index >= peaks.count { peaks.append(contentsOf: repeatElement(0, count: index - peaks.count + 1)) }
                peaks[index] = max(peaks[index], min(1, peak))
                offset += count
                position += count
            }
        }) {
            chunks += 1
            if chunks % 64 == 0 {
                try context.checkCancellation()
                if reader.duration > 0 { context.progress(Double(peaks.count) / Double(max(1, expected))) }
            }
        }
        return peaks
    }

    static func write(_ waveform: Waveform, sourceRate: Double, channels: Int, into folder: URL) throws {
        let header = Header(samplesPerSecond: waveform.samplesPerSecond, count: waveform.peaks.count, sourceSampleRate: sourceRate, sourceChannels: channels)
        try CacheJSON.write(header, to: folder.appendingPathComponent(headerFile))
        let data = waveform.peaks.map { $0.bitPattern.littleEndian }.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: folder.appendingPathComponent(peaksFile))
    }

    static func read(from folder: URL) -> Waveform? {
        guard let header = CacheJSON.read(Header.self, from: folder.appendingPathComponent(headerFile)),
              let data = try? Data(contentsOf: folder.appendingPathComponent(header.file)),
              data.count >= header.count * 4
        else { return nil }
        let peaks = data.withUnsafeBytes { raw in
            (0..<header.count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        return Waveform(samplesPerSecond: header.samplesPerSecond, peaks: peaks)
    }
}

/// EBU R128 loudness of the whole file, with `LoudnessMeter`.
enum LoudnessJob {
    static let file = "loudness.json"

    static func run(source: URL, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws {
        let loudness = try await measure(source: source, context: context, timeRange: timeRange)
        try CacheJSON.write(loudness, to: folder.appendingPathComponent(file))
    }

    static func measure(source: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws -> Loudness {
        let reader = try await AudioReader(url: source, timeRange: timeRange)
        return try await Blocking.run(qos: context.qos) {
            var meter = LoudnessMeter(sampleRate: reader.sampleRate, channels: reader.channels)
            // Decoders hand out about a thousand frames at a time; the meter
            // is much quicker fed in larger blocks.
            let blockFrames = 32_768
            var block: [Float] = []
            block.reserveCapacity(blockFrames * reader.channels)
            var seconds = 0.0
            var chunks = 0
            func flush() {
                guard !block.isEmpty else { return }
                meter.process(interleaved: block)
                block.removeAll(keepingCapacity: true)
            }
            while try reader.next({ samples, frames, _ in
                block.append(contentsOf: samples)
                seconds += Double(frames) / reader.sampleRate
                if block.count >= blockFrames * reader.channels { flush() }
            }) {
                chunks += 1
                if chunks % 256 == 0 {
                    try context.checkCancellation()
                    if reader.duration > 0 { context.progress(seconds / reader.duration) }
                }
            }
            flush()
            return meter.result()
        }
    }

    static func read(from folder: URL) -> Loudness? {
        CacheJSON.read(Loudness.self, from: folder.appendingPathComponent(file))
    }
}
