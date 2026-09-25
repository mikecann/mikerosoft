import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import VideoToolbox

/// Writes frames drawn with Core Graphics into a QuickTime movie as HEVC
/// with alpha, the one format every sticker ends up in. AVFoundation
/// decodes it with its alpha intact, it's small (a 5 s sticker is a few
/// hundred KB) and it plays like any other clip.
final class AlphaVideoWriter {
    let url: URL
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var framesWritten = 0

    /// `width` and `height` are rounded up to even numbers, which HEVC needs.
    init(url: URL, width: Int, height: Int, quality: Double = 0.9) throws {
        self.url = url
        self.width = max(2, width + width % 2)
        self.height = max(2, height + height % 2)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                // Core Graphics draws premultiplied; say so, so decoders
                // hand back the same thing.
                kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha,
                kVTCompressionPropertyKey_Quality as String: quality,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: quality
            ] as [String: Any]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height
        ])
        guard writer.canAdd(input) else { throw AssetError.normaliseFailed("can't write HEVC with alpha") }
        writer.add(input)
        guard writer.startWriting() else {
            throw AssetError.normaliseFailed("can't start writing \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Appends `image` fitted and centred in the frame.
    func append(_ image: CGImage, at time: CMTime) throws {
        try append(at: time) { context, width, height in
            let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
            let drawWidth = Double(image.width) * scale
            let drawHeight = Double(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (Double(width) - drawWidth) / 2, y: (Double(height) - drawHeight) / 2, width: drawWidth, height: drawHeight))
        }
    }

    /// Appends a frame drawn by `draw` into a cleared context (origin at the
    /// bottom left, as usual for Core Graphics).
    func append(at time: CMTime, draw: (CGContext, Int, Int) throws -> Void) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { break }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard writer.status == .writing, let pool = adaptor.pixelBufferPool else {
            throw AssetError.normaliseFailed("writer stopped: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { throw AssetError.normaliseFailed("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw AssetError.normaliseFailed("no drawing context") }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        try draw(context, width, height)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw AssetError.normaliseFailed("appending frame \(framesWritten): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        framesWritten += 1
    }

    /// Ends the movie at `endTime`, so the last frame keeps its duration.
    func finish(endTime: CMTime) async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: endTime)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AssetError.normaliseFailed("finishing \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}

/// An animated GIF or WebP, decoded frame by frame with ImageIO (which
/// keeps alpha and composites each frame for us).
struct AnimatedImage {
    let source: CGImageSource
    let frameCount: Int
    /// Seconds each frame shows for.
    let delays: [Double]
    let width: Int
    let height: Int

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AssetError.normaliseFailed("can't read \(url.lastPathComponent)")
        }
        self.source = source
        frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw AssetError.normaliseFailed("\(url.lastPathComponent) has no frames") }
        delays = (0..<frameCount).map { Self.delay(source, $0) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
        width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? first?.width ?? 0
        height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? first?.height ?? 0
    }

    var duration: Double { delays.reduce(0, +) }

    func frame(_ index: Int) -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Frame delay as browsers play it: very short delays mean 0.1 s.
    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let dictionary = (properties[kCGImagePropertyGIFDictionary] ?? properties[kCGImagePropertyWebPDictionary] ?? properties[kCGImagePropertyPNGDictionary]) as? [CFString: Any] ?? [:]
        let unclamped = (dictionary[kCGImagePropertyGIFUnclampedDelayTime] ?? dictionary[kCGImagePropertyWebPUnclampedDelayTime] ?? dictionary[kCGImagePropertyAPNGUnclampedDelayTime]) as? Double
        let clamped = (dictionary[kCGImagePropertyGIFDelayTime] ?? dictionary[kCGImagePropertyWebPDelayTime] ?? dictionary[kCGImagePropertyAPNGDelayTime]) as? Double
        if let unclamped, unclamped >= 0.02 { return unclamped }
        if let clamped, clamped >= 0.02 { return clamped }
        return 0.1
    }

    /// Writes every frame at its own time into HEVC with alpha. Equal delays
    /// give a constant frame rate; mixed delays keep their exact timing.
    func writeHEVCWithAlpha(to url: URL) async throws -> VideoInfo {
        let writer = try AlphaVideoWriter(url: url, width: width, height: height)
        let timescale: CMTimeScale = 6_000
        var elapsed = 0.0
        do {
            for index in 0..<frameCount {
                // A frame that won't decode leaves the previous one showing
                // for its time, so the timing stays true.
                if let image = frame(index) {
                    try writer.append(image, at: CMTime(value: CMTimeValue((elapsed * Double(timescale)).rounded()), timescale: timescale))
                }
                elapsed += delays[index]
            }
            try await writer.finish(endTime: CMTime(value: CMTimeValue((elapsed * Double(timescale)).rounded()), timescale: timescale))
        } catch {
            writer.cancel()
            throw error
        }
        let rate = delays.isEmpty ? nil : 1 / (delays.reduce(0, +) / Double(delays.count))
        return VideoInfo(duration: elapsed, width: writer.width, height: writer.height, frameRate: rate, hasAlpha: true, hasAudio: false, hasVideo: true)
    }
}
