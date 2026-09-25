import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import TandemCore

/// One stretch of the timeline for the compositor: its layer stack and the
/// composition tracks holding the frames it needs.
final class TandemInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let stack: [StackNode]
    let scene: RenderScene
    /// Composition track ID for each video pool index.
    let trackIDs: [CMPersistentTrackID]

    init(range: TimeRange, stack: [StackNode], scene: RenderScene, trackIDs: [CMPersistentTrackID]) {
        self.timeRange = range.cmTimeRange
        self.stack = stack
        self.scene = scene
        self.trackIDs = trackIDs
        var needed = Set<CMPersistentTrackID>()
        for node in stack {
            for layer in node.layers {
                for pool in [layer.pictureTrack, layer.matteTrack].compactMap({ $0 }) where trackIDs.indices.contains(pool) {
                    needed.insert(trackIDs[pool])
                }
            }
        }
        self.requiredSourceTrackIDs = needed.sorted().map { NSNumber(value: $0) }
    }
}

/// Tandem's `AVVideoCompositing`: renders each frame with `FrameComposer`
/// on the shared Metal-backed Core Image context. Used by the viewer, frame
/// grabs and export alike.
class TandemCompositor: NSObject, AVVideoCompositing {
    /// 8-bit 4:2:0 video range, which the VideoToolbox encoders take as is.
    class var outputPixelFormat: OSType { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
    /// True for frame grabs, where every frame is a seek.
    class var rendersStills: Bool { false }

    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.compositor", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var generation = 0

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            // Decoders' native formats, so frames arrive without conversion.
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_32BGRA
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: type(of: self).outputPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let started = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            self.lock.lock()
            let cancelled = started != self.generation
            self.lock.unlock()
            if cancelled {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool { self.render(request) }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? TandemInstruction else {
            request.finish(with: RenderError.compositor("unexpected instruction"))
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: RenderError.compositor("no output buffer"))
            return
        }
        let time = Time(cmTime: request.compositionTime)
        let sources = RequestSources(request: request, trackIDs: instruction.trackIDs)
        var image = FrameComposer(scene: instruction.scene, stills: type(of: self).rendersStills).compose(instruction.stack, at: time, sources: sources)

        // A player or frame grab may ask for a smaller frame than the canvas.
        let canvas = instruction.scene.canvas
        let outSize = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        if outSize != canvas {
            image = image.transformed(by: CGAffineTransform(scaleX: outSize.width / canvas.width, y: outSize.height / canvas.height), highQualityDownsample: true)
        }

        // Tag the frame BT.709 so Core Image converts to YCbCr with that
        // matrix, and the tags travel on to the encoder.
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = nil
        do {
            let task = try RenderEngine.context.startTask(toRender: image.cropped(to: CGRect(origin: .zero, size: outSize)), to: destination)
            _ = try task.waitUntilCompleted()
            request.finish(withComposedVideoFrame: output)
        } catch {
            request.finish(with: error)
        }
    }
}

/// The same compositor with RGBA output, for frame grabs: no chroma
/// subsampling or video-range round trip in PNGs and golden tests.
final class TandemRGBCompositor: TandemCompositor {
    override class var outputPixelFormat: OSType { kCVPixelFormatType_32BGRA }
    override class var rendersStills: Bool { true }
}

/// Source frames from an AVFoundation request.
struct RequestSources: FrameSources {
    let request: AVAsynchronousVideoCompositionRequest
    let trackIDs: [CMPersistentTrackID]

    func frame(track: Int) -> CIImage? {
        guard trackIDs.indices.contains(track), let buffer = request.sourceFrame(byTrackID: trackIDs[track]) else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }
}

public enum RenderError: Error, CustomStringConvertible, Equatable {
    case emptyTimeline
    case compositor(String)
    case media(String)
    case export(String)
    case cancelled

    public var description: String {
        switch self {
        case .emptyTimeline: return "The timeline is empty."
        case .compositor(let message): return "Compositor: \(message)"
        case .media(let message): return message
        case .export(let message): return "Export failed: \(message)"
        case .cancelled: return "Export cancelled."
        }
    }
}
