import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Small media files made inside the tests, so nothing depends on footage
/// that might not be on the machine.
enum SyntheticMedia {
    struct Audio {
        var frequency = 440.0
        /// Linear peak amplitude, 0...1.
        var amplitude = 0.5
        var sampleRate = 48_000.0
        var channels = 2
    }

    struct Video {
        var width = 320
        var height = 180
        var fps = 30
        var duration = 2.0
        /// Explicit presentation times in seconds (VFR). Overrides fps and
        /// duration; the last frame lasts one nominal frame.
        var frameTimes: [Double]?
        var codec: AVVideoCodecType = .h264
        var audio: Audio? = Audio()
        var transform: CGAffineTransform = .identity
        /// Written as QuickTime creation-date metadata when set.
        var creationDate: Date?
        /// Keyframe every frame, so tests that seek are exact and fast.
        var allIntra = false
    }

    /// Writes a movie of solid colour frames (the colour steps each frame)
    /// with an optional sine track.
    static func writeMovie(to url: URL, _ spec: Video) async throws {
        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        var compression: [String: Any] = [:]
        if spec.allIntra { compression[AVVideoMaxKeyFrameIntervalKey] = 1 }
        if spec.codec == .h264 { compression[AVVideoAllowFrameReorderingKey] = false }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height
        ]
        if !compression.isEmpty { videoSettings[AVVideoCompressionPropertiesKey] = compression }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = spec.transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height
        ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audio = spec.audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        if let date = spec.creationDate {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = ISO8601DateFormatter.fractional.string(from: date) as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [item]
        }

        guard writer.startWriting() else { throw writer.error ?? TestMediaError("could not start writing \(url.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)

        let times: [Double] = spec.frameTimes ?? (0..<Int((spec.duration * Double(spec.fps)).rounded())).map { Double($0) / Double(spec.fps) }
        let endTime = (times.last ?? 0) + 1 / Double(spec.fps)

        let videoDone = Task.detached {
            let timescale: CMTimeScale = 600 * 1000
            for (index, time) in times.enumerated() {
                while !videoInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                let buffer = try makeFrame(width: spec.width, height: spec.height, index: index, pool: adaptor.pixelBufferPool)
                let pts = CMTime(value: CMTimeValue((time * Double(timescale)).rounded()), timescale: timescale)
                guard adaptor.append(buffer, withPresentationTime: pts) else {
                    throw writer.error ?? TestMediaError("video append failed")
                }
            }
            videoInput.markAsFinished()
        }
        let audioDone = Task.detached {
            guard let audioInput, let audio = spec.audio else { return }
            let totalFrames = Int(endTime * audio.sampleRate)
            let chunk = 4096
            var written = 0
            while written < totalFrames {
                while !audioInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                let count = min(chunk, totalFrames - written)
                let buffer = try makeSineSampleBuffer(audio, startFrame: written, frames: count)
                guard audioInput.append(buffer) else { throw writer.error ?? TestMediaError("audio append failed") }
                written += count
            }
            audioInput.markAsFinished()
        }
        try await videoDone.value
        try await audioDone.value
        writer.endSession(atSourceTime: CMTime(seconds: endTime, preferredTimescale: 600_000))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? TestMediaError("writer ended as \(writer.status.rawValue)") }
    }

    /// Writes 16-bit PCM WAV (or AIFF/CAF by extension) made of sine
    /// segments, so amplitudes survive exactly.
    static func writeAudioFile(to url: URL, segments: [(seconds: Double, amplitude: Double)], frequency: Double = 1000, sampleRate: Double = 48_000, channels: Int = 2) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var phaseFrame = 0
        for segment in segments {
            let frames = Int(segment.seconds * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<channels {
                let data = buffer.floatChannelData![channel]
                for i in 0..<frames {
                    data[i] = Float(segment.amplitude * sin(2 * Double.pi * frequency * Double(phaseFrame + i) / sampleRate))
                }
            }
            phaseFrame += frames
            try file.write(from: buffer)
        }
    }

    static func writePNG(to url: URL, width: Int, height: Int, alpha: Bool) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestMediaError("png write failed") }
    }

    /// A BGRA frame filled with a colour that changes with `index`.
    static func makeFrame(width: Int, height: Int, index: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { throw TestMediaError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var image = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(buffer),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        // BGRA in memory; vImage's ARGB8888 fill writes the four bytes in order.
        let colour: [UInt8] = [UInt8((index * 40) % 256), UInt8((index * 17) % 256), UInt8(200 - (index * 7) % 150), 255]
        _ = vImageBufferFill_ARGB8888(&image, colour, vImage_Flags(kvImageNoFlags))
        return buffer
    }

    static func makeSineSampleBuffer(_ audio: Audio, startFrame: Int, frames: Int) throws -> CMSampleBuffer {
        let channels = audio.channels
        var samples = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let value = Float(audio.amplitude * sin(2 * Double.pi * audio.frequency * Double(startFrame + i) / audio.sampleRate))
            for c in 0..<channels { samples[i * channels + c] = value }
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: audio.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let byteCount = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard let block, let format else { throw TestMediaError("no audio block") }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(audio.sampleRate))
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw TestMediaError("no audio sample buffer") }
        return sampleBuffer
    }
}

struct TestMediaError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// A fresh folder under the system temp directory, removed on tear down.
class TempFolderTestCase: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandem-media-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }

    func file(_ relative: String) -> URL {
        let url = temp.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func touch(_ relative: String, contents: String = "x") {
        FileManager.default.createFile(atPath: file(relative).path, contents: Data(contents.utf8))
    }
}
