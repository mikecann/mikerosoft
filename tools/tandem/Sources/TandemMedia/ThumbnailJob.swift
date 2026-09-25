import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import TandemCore
import UniformTypeIdentifiers

/// A filmstrip: one JPEG every `interval` seconds of media at a fixed width,
/// or a single thumbnail for an image. `strip.json` lists the files in time
/// order, so file `i` shows the media at `i * interval`.
enum ThumbnailJob {
    static let stripFile = "strip.json"
    static let jpegQuality = 0.7

    static func run(source: URL, kind: MediaKind, interval: Double, width: Int, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws {
        let strip: ThumbnailStrip
        if kind == .image {
            strip = try imageThumbnail(source: source, width: width, into: folder)
        } else {
            strip = try await filmstrip(source: source, interval: interval, width: width, into: folder, context: context, timeRange: timeRange)
        }
        try CacheJSON.write(strip, to: folder.appendingPathComponent(stripFile))
    }

    static func filmstrip(source: URL, interval: Double, width: Int, into folder: URL, context: JobContext, timeRange: CMTimeRange?) async throws -> ThumbnailStrip {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        guard let track = tracks.first(where: { $0.mediaType == .video }) else {
            throw MediaError.notApplicable("\(source.lastPathComponent) has no video")
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = size.applying(transform)
        let (displayWidth, displayHeight) = (abs(display.width), abs(display.height))
        guard displayWidth > 0, displayHeight > 0 else { throw MediaError.failed("\(source.lastPathComponent) has an empty picture") }
        let thumbWidth = width
        let thumbHeight = max(2, Int((Double(width) * Double(displayHeight) / Double(displayWidth) / 2).rounded()) * 2)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbWidth, height: thumbHeight)
        // Half an interval either way lets the decoder use nearby keyframes,
        // which is many times faster than exact frames and fine for a strip.
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let start = timeRange?.start.seconds ?? 0
        let length = timeRange?.duration.seconds ?? duration.seconds
        let count = max(1, Int((length / interval).rounded(.up)))
        let times = (0..<count).map { CMTime(seconds: start + Double($0) * interval, preferredTimescale: 600) }
        var files = [String?](repeating: nil, count: count)
        var done = 0
        // Stops outstanding decodes if the job is cancelled part way.
        defer { generator.cancelAllCGImageGeneration() }
        for await result in generator.images(for: times) {
            try context.checkCancellation()
            if case .success(let requested, let image, _) = result {
                let index = min(count - 1, max(0, Int(((requested.seconds - start) / interval).rounded())))
                let name = String(format: "t%05d.jpg", index)
                try writeJPEG(image, to: folder.appendingPathComponent(name))
                files[index] = name
            }
            done += 1
            if done % 16 == 0 { context.progress(Double(done) / Double(count)) }
        }
        guard files.contains(where: { $0 != nil }) else {
            throw MediaError.failed("No frames could be read from \(source.lastPathComponent)")
        }
        // A frame that couldn't be decoded borrows its nearest neighbour, so
        // index i still means time i * interval.
        let filled = files.indices.map { index -> String in
            if let name = files[index] { return name }
            for distance in 1..<count {
                if index - distance >= 0, let name = files[index - distance] { return name }
                if index + distance < count, let name = files[index + distance] { return name }
            }
            return files.compactMap { $0 }.first!
        }
        return ThumbnailStrip(interval: interval, files: filled, width: thumbWidth, height: thumbHeight)
    }

    static func imageThumbnail(source: URL, width: Int, into folder: URL) throws -> ThumbnailStrip {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw MediaError.unreadable(source.lastPathComponent, "ImageIO can't read it") }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let (displayWidth, displayHeight) = rotated ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight)
        // The thumbnail API sizes by the longer side.
        let longest = max(displayWidth, displayHeight)
        let maxPixels = Int((Double(width) * Double(longest) / Double(max(1, displayWidth))).rounded())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, longest)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw MediaError.failed("Couldn't make a thumbnail of \(source.lastPathComponent)")
        }
        let name = "t00000.jpg"
        try writeJPEG(image, to: folder.appendingPathComponent(name))
        return ThumbnailStrip(interval: 0, files: [name], width: image.width, height: image.height)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaError.failed("Couldn't write \(url.lastPathComponent)")
        }
        // JPEG has no alpha: flatten transparent images onto black.
        let opaque = image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst ? image : flattened(image) ?? image
        CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.failed("Couldn't write \(url.lastPathComponent)") }
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func read(from folder: URL) -> ThumbnailStrip? {
        CacheJSON.read(ThumbnailStrip.self, from: folder.appendingPathComponent(stripFile))
    }
}
