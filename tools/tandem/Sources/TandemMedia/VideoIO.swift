import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes a file's first video track frame by frame, in presentation
/// order, in the track's own range (420f for full range sources, 420v for
/// video range), with the track details the proxy and matte writers copy.
final class VideoFrameReader: @unchecked Sendable {
    /// Encoded size, before the track's rotation.
    let size: CGSize
    let transform: CGAffineTransform
    let timescale: CMTimeScale
    let colors: ColorTags
    let pixelFormat: OSType
    let nominalFrameRate: Double
    /// Where the last frame ends: the track's end, or the range's.
    let endTime: CMTime
    /// Frames in the file (or range), from the sample table.
    let frameCount: Int

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    /// Decoding and cancelling happen on different threads (a job's decode
    /// thread and whoever stops the job). AVAssetReader crashes if it's
    /// cancelled mid-copy, so the two take turns.
    private let access = NSRecursiveLock()
    private var cancelled = false

    init(url: URL, timeRange: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.notApplicable("\(url.lastPathComponent) has no video")
        }
        let (size, transform, timescale, formats, rate, trackRange) = try await track.load(
            .naturalSize, .preferredTransform, .naturalTimeScale, .formatDescriptions, .nominalFrameRate, .timeRange
        )
        self.size = size
        self.transform = transform
        self.timescale = timescale
        colors = ColorTags(formats.first)
        pixelFormat = colors.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        nominalFrameRate = Double(rate)
        let range = timeRange.map { $0.intersection(trackRange) } ?? trackRange
        endTime = range.end

        // Count frames from the sample table for progress; no decoding.
        if let times = MediaProbe.presentationTimes(of: track) {
            let start = CMTimeConvertScale(range.start, timescale: timescale, method: .roundTowardNegativeInfinity).value
            let end = CMTimeConvertScale(range.end, timescale: timescale, method: .roundTowardPositiveInfinity).value
            frameCount = times.filter { $0 >= start && $0 < end }.count
        } else {
            frameCount = Int(range.duration.seconds * Double(max(1, rate)))
        }

        reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.failed("Can't decode \(url.lastPathComponent)") }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.unreadable(url.lastPathComponent, reader.error?.localizedDescription ?? "the video can't be decoded")
        }
    }

    /// The next frame and when it's shown, or nil at the end.
    func next() throws -> (buffer: CVPixelBuffer, time: CMTime)? {
        access.lock()
        defer { access.unlock() }
        guard !cancelled else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            // Samples without pixels (markers, empty edits) are skipped.
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (buffer, CMSampleBufferGetPresentationTimeStamp(sample))
        }
        if reader.status == .failed {
            throw MediaError.failed("Video decoding failed: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        return nil
    }

    func cancel() {
        access.lock()
        defer { access.unlock() }
        guard !cancelled else { return }
        cancelled = true
        reader.cancelReading()
    }
}

/// Scales frames on the GPU with VideoToolbox, keeping the pixel format and
/// the colour attachments.
final class PixelScaler: @unchecked Sendable {
    let width: Int
    let height: Int
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int, pixelFormat: OSType) throws {
        self.width = width
        self.height = height
        var created: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created)
        guard let created else { throw MediaError.failed("VideoToolbox couldn't start a scaler") }
        session = created
        pool = try makePixelBufferPool(width: width, height: height, pixelFormat: pixelFormat)
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    func scale(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        if CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height { return source }
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard let destination else { throw MediaError.failed("Out of video memory") }
        CVBufferPropagateAttachments(source, destination)
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else { throw MediaError.failed("Scaling a frame failed (\(status))") }
        return destination
    }
}

func makePixelBufferPool(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: pixelFormat,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
    ]
    CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard let pool else { throw MediaError.failed("Couldn't make a \(width)x\(height) frame pool") }
    return pool
}

/// 1080p all-intra HEVC copy of a video, for smooth scrubbing. Every source
/// frame keeps its exact presentation time and duration, so proxy time is
/// source time even for variable frame rate screen recordings. Video only.
enum ProxyJob {
    static let file = "proxy.mov"

    static func run(source: URL, settings: AnalysisSettings, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws {
        let reader = try await VideoFrameReader(url: source, timeRange: timeRange)
        let size = fittedSize(width: Int(reader.size.width), height: Int(reader.size.height), maxWidth: settings.proxyMaxWidth, maxHeight: settings.proxyMaxHeight)
        let scaler = try PixelScaler(width: size.width, height: size.height, pixelFormat: reader.pixelFormat)
        let writer = try EncodedMovieWriter(url: folder.appendingPathComponent(file), settings: .init(
            width: size.width, height: size.height, keyFrameInterval: 1, quality: settings.proxyQuality, prioritizeSpeed: true,
            colorPrimaries: reader.colors.primaries, transferFunction: reader.colors.transfer, yCbCrMatrix: reader.colors.matrix,
            timescale: reader.timescale, transform: reader.transform, expectedFrameRate: reader.nominalFrameRate > 0 ? reader.nominalFrameRate : nil
        ))
        await context.acquireEncoder()
        let counter = FrameCounter()
        do {
            while true {
                let more = try await Blocking.run(qos: context.qos) { () -> Bool in
                    for _ in 0..<30 {
                        guard let frame = try reader.next() else { return false }
                        try writer.append(try scaler.scale(frame.buffer), at: frame.time)
                        counter.count += 1
                    }
                    return true
                }
                context.progress(Double(counter.count) / Double(max(1, reader.frameCount)), message: "Frame \(counter.count) of \(reader.frameCount)")
                if !more { break }
                try await context.checkpoint()
            }
            try await writer.finish(endTime: reader.endTime)
        } catch {
            reader.cancel()
            writer.cancel()
            throw error
        }
    }
}

final class FrameCounter: @unchecked Sendable {
    var count = 0
}
