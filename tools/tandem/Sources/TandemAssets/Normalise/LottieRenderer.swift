import CoreMedia
import Foundation

#if canImport(Lottie)
import Lottie
import QuartzCore

/// Renders Lottie animations offscreen, with alpha, into HEVC with alpha at
/// import, so the renderer only ever sees video.
///
/// Lottie's layers belong to the main actor, so each frame is drawn there
/// (a few milliseconds at 1024 square) and handed to the writer off it.
/// About 1.5 to 2.3 s for 140 frames on an M5 Pro.
enum LottieRenderer {
    static let isAvailable = true

    static func render(_ url: URL, to output: URL, longSide: Int) async throws -> VideoInfo {
        let renderer = try await LottieFrameRenderer.make(url: url, longSide: longSide)
        let fps = renderer.framesPerSecond
        let writer = try AlphaVideoWriter(url: output, width: renderer.width, height: renderer.height)
        // Frame times on a 60 000 tick clock are exact for 24, 25, 30, 50
        // and 60 fps.
        let timescale: CMTimeScale = 60_000
        var index = 0
        do {
            for frame in renderer.frameRange {
                let image = try await renderer.image(at: CGFloat(frame))
                let time = CMTime(value: CMTimeValue((Double(index) / fps * Double(timescale)).rounded()), timescale: timescale)
                try writer.append(image, at: time)
                index += 1
            }
            let end = CMTime(value: CMTimeValue((Double(index) / fps * Double(timescale)).rounded()), timescale: timescale)
            try await writer.finish(endTime: end)
        } catch {
            writer.cancel()
            throw error
        }
        return VideoInfo(duration: Double(index) / fps, width: writer.width, height: writer.height, frameRate: fps, hasAlpha: true, hasAudio: false, hasVideo: true)
    }
}

/// One Lottie animation laid out at the output size.
@MainActor
final class LottieFrameRenderer {
    let layer: LottieAnimationLayer
    let width: Int
    let height: Int
    let frameRange: StrideTo<CGFloat>
    let framesPerSecond: Double
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func make(url: URL, longSide: Int) throws -> LottieFrameRenderer {
        guard let animation = LottieAnimation.filepath(url.path) else {
            throw AssetError.normaliseFailed("can't read Lottie animation \(url.lastPathComponent)")
        }
        return LottieFrameRenderer(animation: animation, longSide: longSide)
    }

    private init(animation: LottieAnimation, longSide: Int) {
        let size = animation.size
        let scale = Double(longSide) / max(size.width, size.height, 1)
        width = max(2, Int((size.width * scale).rounded()))
        height = max(2, Int((size.height * scale).rounded()))
        framesPerSecond = animation.framerate > 0 ? animation.framerate : 30
        frameRange = stride(from: animation.startFrame, to: animation.endFrame, by: 1)
        // The main-thread engine draws into any context; the Core Animation
        // engine only animates on screen.
        layer = LottieAnimationLayer(animation: animation, configuration: LottieConfiguration(renderingEngine: .mainThread))
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        layer.contentsGravity = .resizeAspect
        layer.layoutIfNeeded()
    }

    func image(at frame: CGFloat) throws -> CGImage {
        layer.currentFrame = frame
        layer.forceDisplayUpdate()
        layer.setNeedsLayout()
        layer.layoutIfNeeded()
        // Keep the animation centred; the main-thread engine positions its
        // root layer at the origin.
        layer.sublayers?.forEach { $0.position = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2) }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AssetError.normaliseFailed("no drawing context for Lottie")
        }
        // Layers draw top-down; bitmap contexts are bottom-up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { throw AssetError.normaliseFailed("rendering Lottie frame \(frame)") }
        return image
    }
}
#else
/// Lottie rendering needs the lottie-ios package. Without it, Lottie
/// originals fall back to the animated WebP fetched with them.
enum LottieRenderer {
    static let isAvailable = false

    static func render(_ url: URL, to output: URL, longSide: Int) async throws -> VideoInfo {
        throw AssetError.unsupported("Lottie rendering needs the lottie-ios package, which isn't in this build")
    }
}
#endif
