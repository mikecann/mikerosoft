import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import TandemMedia
import UniformTypeIdentifiers

/// Browser tiles for every kind of asset: a frame for video and stickers, a
/// scaled copy for images, a waveform for audio and a sample for fonts.
///
/// Thumbnails with transparency are PNG (`thumbnail.png`) so an icon still
/// reads on the tile; everything else is JPEG (`thumbnail.jpg`).
enum Thumbnailer {
    static let maxPixelSize = 512
    /// The Graphite tile background, for thumbnails that draw their own.
    static let background = CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let foreground = CGColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1)

    /// Writes `image` as the folder's thumbnail and returns the file name.
    static func write(_ image: CGImage, into folder: URL) throws -> String {
        let alpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = false
        default: alpha = true
        }
        let name = alpha ? "thumbnail.png" : "thumbnail.jpg"
        // Only one thumbnail per folder.
        for other in ["thumbnail.png", "thumbnail.jpg"] where other != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(other))
        }
        try ImageFiles.write(image, to: folder.appendingPathComponent(name), type: alpha ? .png : .jpeg)
        return name
    }

    static func image(_ url: URL, into folder: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AssetError.normaliseFailed("can't read \(url.lastPathComponent) for a thumbnail")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AssetError.normaliseFailed("no thumbnail for \(url.lastPathComponent)")
        }
        return try write(thumbnail, into: folder)
    }

    /// A frame from `fraction` of the way through, which for stickers is
    /// usually mid-motion and for stock clips past any fade-in.
    static func video(_ url: URL, into folder: URL, fraction: Double = 0.4) async throws -> String {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let seconds = duration.seconds.isFinite ? duration.seconds * fraction : 0
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return try write(image, into: folder)
    }

    /// Bars for the loudest point of each column, mirrored about the middle.
    static func waveform(_ waveform: Waveform, into folder: URL, width: Int = 512, height: Int = 128) throws -> String {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw AssetError.normaliseFailed("no drawing context")
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(foreground)
        let peaks = waveform.peaks
        let middle = Double(height) / 2
        if !peaks.isEmpty {
            let columns = width / 2
            for column in 0..<columns {
                let start = column * peaks.count / columns
                let end = max(start + 1, (column + 1) * peaks.count / columns)
                let peak = peaks[min(start, peaks.count - 1)..<min(end, peaks.count)].max() ?? 0
                let bar = max(1, Double(peak) * (middle - 4))
                context.fill(CGRect(x: Double(column * 2), y: middle - bar, width: 1, height: bar * 2))
            }
        }
        guard let image = context.makeImage() else { throw AssetError.normaliseFailed("drawing waveform") }
        return try write(image, into: folder)
    }

    /// "Aa" and the family name, set in the font itself.
    static func font(_ url: URL, into folder: URL, width: Int = 512, height: Int = 256) throws -> String {
        guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first else {
            throw AssetError.normaliseFailed("no fonts in \(url.lastPathComponent)")
        }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw AssetError.normaliseFailed("no drawing context")
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? url.deletingPathExtension().lastPathComponent
        func draw(_ text: String, size: Double, y: Double) {
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetImageBounds(line, context)
            context.textPosition = CGPoint(x: (Double(width) - bounds.width) / 2 - bounds.minX, y: y)
            CTLineDraw(line, context)
        }
        draw("Aa", size: 120, y: 100)
        draw(family, size: 28, y: 32)
        guard let image = context.makeImage() else { throw AssetError.normaliseFailed("drawing font sample") }
        return try write(image, into: folder)
    }
}
