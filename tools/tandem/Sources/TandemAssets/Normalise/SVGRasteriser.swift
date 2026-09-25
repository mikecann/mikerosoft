// The one AppKit import outside the app: NSImage is the only public API on
// macOS that renders SVG (ImageIO doesn't read it). Drawing happens into
// our own bitmap context, so this is safe off the main thread.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// SVG icons and logos to PNG, so the renderer only ever sees bitmaps.
enum SVGRasteriser {
    /// Renders `svg` so its longer side is `longSide` pixels (twice the
    /// largest size it's likely to be shown at) and writes a PNG with alpha.
    static func rasterise(_ svg: URL, to png: URL, longSide: Int) throws -> (width: Int, height: Int) {
        guard let image = NSImage(contentsOf: svg), image.size.width > 0, image.size.height > 0 else {
            throw AssetError.normaliseFailed("can't read SVG \(svg.lastPathComponent)")
        }
        let scale = Double(longSide) / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AssetError.normaliseFailed("no drawing context for \(svg.lastPathComponent)")
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let bitmap = context.makeImage() else { throw AssetError.normaliseFailed("rendering \(svg.lastPathComponent)") }
        try ImageFiles.write(bitmap, to: png, type: .png)
        return (width, height)
    }
}

/// Writing CGImages to disk with ImageIO.
enum ImageFiles {
    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.85) throws {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw AssetError.normaliseFailed("can't write \(url.lastPathComponent)")
        }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AssetError.normaliseFailed("can't finish \(url.lastPathComponent)") }
    }
}
