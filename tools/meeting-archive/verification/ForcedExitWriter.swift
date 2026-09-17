import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case usage
    case media(String)

    var description: String {
        switch self {
        case .usage: "Usage: ForcedExitWriter write-crash OUTPUT_DIR | inspect OUTPUT_DIR"
        case .media(let message): message
        }
    }
}

@main
private enum ForcedExitWriter {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else { throw FixtureFailure.usage }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        switch arguments[0] {
        case "write-crash":
            try writeThenCrash(directory)
        case "inspect":
            try await inspect(directory)
        default:
            throw FixtureFailure.usage
        }
    }

    private static func writeThenCrash(_ directory: URL) throws -> Never {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let origin = CMTime.zero
        let firstVideo = try videoSample(frame: 0)
        let firstAudio = try audioSample(block: 0, frequency: 440)
        let video = try TrackWriter(track: .video, directory: directory, sample: firstVideo, origin: origin)
        let microphone = try TrackWriter(track: .microphone, directory: directory, sample: firstAudio, origin: origin)
        let incoming = try TrackWriter(
            track: .incoming,
            directory: directory,
            sample: try audioSample(block: 0, frequency: 660),
            origin: origin
        )

        // Six seconds spans three two-second movie fragments. The process exits
        // without finish(), measuring what the production writer has actually
        // made recoverable at a crash boundary.
        for frame in 0..<(6 * 15) {
            try waitUntilReady(video)
            try video.append(try videoSample(frame: frame))
            if frame % 3 == 0 {
                let block = frame / 3
                try waitUntilReady(microphone)
                try waitUntilReady(incoming)
                try microphone.append(try audioSample(block: block, frequency: 440))
                try incoming.append(try audioSample(block: block, frequency: 660))
            }
            usleep(2_000)
        }
        // Give the hardware encoders time to publish their latest full fragment,
        // then terminate without any Swift defer or AVAssetWriter finalization.
        usleep(750_000)
        _exit(0)
    }

    private static func waitUntilReady(_ writer: TrackWriter) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !writer.ready, ProcessInfo.processInfo.systemUptime < deadline { usleep(1_000) }
        guard writer.ready else { throw FixtureFailure.media("Encoder did not become ready within five seconds") }
    }

    private static func videoSample(frame: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920,
            1080,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw FixtureFailure.media("Could not allocate a video fixture pixel buffer: \(result)")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            memset(luma, Int32(32 + frame % 160), CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * 1080)
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * 540)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            throw FixtureFailure.media("Could not create a video format description")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMTime(value: Int64(frame), timescale: 15),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw FixtureFailure.media("Could not create a video sample buffer")
        }
        return sample
    }

    private static func audioSample(block: Int, frequency: Double) throws -> CMSampleBuffer {
        let sampleRate = 48_000.0
        let frames = 9_600 // 200 ms, matching each three video frames.
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            throw FixtureFailure.media("Could not create an audio format description")
        }

        var pcm = [Int16](repeating: 0, count: frames)
        for index in pcm.indices {
            let absoluteFrame = block * frames + index
            pcm[index] = Int16(sin(2 * .pi * frequency * Double(absoluteFrame) / sampleRate) * 8_000)
        }
        let byteCount = pcm.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            throw FixtureFailure.media("Could not allocate an audio block buffer")
        }
        let replaceStatus = pcm.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == noErr else { throw FixtureFailure.media("Could not fill an audio block buffer") }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(block * frames), timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw FixtureFailure.media("Could not create an audio sample buffer")
        }
        return sample
    }

    private static func inspect(_ directory: URL) async throws {
        var ranges: [(String, Double, Double)] = []
        for name in ["meeting-view.mov", "microphone.m4a", "incoming.m4a"] {
            let asset = AVURLAsset(url: directory.appendingPathComponent(name))
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw FixtureFailure.media("\(name) has no recoverable duration")
            }
            guard let track = try await asset.load(.tracks).first else {
                throw FixtureFailure.media("\(name) has no recoverable media track")
            }
            let range = try await track.load(.timeRange)
            ranges.append((name, range.start.seconds, duration))
        }
        let starts = ranges.map(\.1)
        let ends = ranges.map { $0.1 + $0.2 }
        guard (starts.max()! - starts.min()!) <= 0.25 else {
            throw FixtureFailure.media("Recovered source start times drift by more than 250 ms: \(ranges)")
        }
        guard (ends.max()! - ends.min()!) <= 0.25 else {
            throw FixtureFailure.media("Recovered source end times drift by more than 250 ms: \(ranges)")
        }
        guard ranges.allSatisfy({ $0.2 >= 2.0 }) else {
            throw FixtureFailure.media("No complete two-second fragment was recoverable: \(ranges)")
        }
        for range in ranges { print("\(range.0) start=\(range.1) duration=\(range.2)") }
    }
}
