import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import TandemAssets

/// Small media files made on the fly, so no binaries live in the repo.
enum Generated {
    /// A 16-bit PCM WAV of a 1 kHz sine at `dbfs` on every channel.
    static func sineWAV(at url: URL, seconds: Double = 1, sampleRate: Int = 44_100, channels: Int = 2, dbfs: Double = -20, frequency: Double = 1000) throws {
        let amplitude = pow(10, dbfs / 20)
        let frames = Int(seconds * Double(sampleRate))
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = amplitude * sin(2 * Double.pi * frequency * Double(frame) / Double(sampleRate))
            var sample = Int16(max(-32768, min(32767, (value * 32767).rounded()))).littleEndian
            for _ in 0..<channels { pcm.append(Data(bytes: &sample, count: 2)) }
        }
        try WAVFile.wrap(pcm16: pcm, sampleRate: sampleRate, channels: channels).write(to: url)
    }

    /// An animated GIF: a transparent background with an opaque red square
    /// moving right, `frames` frames of `delay` seconds.
    static func animatedGIF(at url: URL, size: Int = 64, frames: Int = 10, delay: Double = 0.05) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw AssetError.invalid("no GIF destination")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frames {
            let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.clear(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: index * 2, y: size / 4, width: size / 2, height: size / 2))
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, context.makeImage()!, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw AssetError.invalid("GIF not written") }
    }

    /// A small SVG: a 100 x 50 blue rectangle with a transparent margin.
    static func svg(at url: URL) throws {
        let text = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60">
          <rect x="10" y="5" width="100" height="50" fill="#0055ff"/>
        </svg>
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A TrueType font that ships with macOS, or nil.
    static func systemFont() -> URL? {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Courier New.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Supplemental/Georgia.ttf",
            "/Library/Fonts/Arial Unicode.ttf"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Alpha of the pixel at (x, y) from the top left, in the frame nearest
    /// `seconds`, decoded the way the renderer will decode it.
    static func alpha(of movie: URL, x: Int, y: Int, at seconds: Double = 0) async throws -> UInt8 {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AssetError.invalid("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var chosen: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            chosen = sample
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds >= seconds { break }
        }
        reader.cancelReading()
        guard let sample = chosen, let buffer = CMSampleBufferGetImageBuffer(sample) else { throw AssetError.invalid("no frames") }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return base[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4 + 3]
    }

    /// Number of video frames in a movie.
    static func frameCount(of movie: URL) async throws -> Int {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return count
    }
}
