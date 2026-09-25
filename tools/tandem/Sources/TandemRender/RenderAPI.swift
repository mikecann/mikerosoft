import AVFoundation
import CoreGraphics
import Foundation
import TandemCore
import TandemMedia

// Contract for the render module. The API and the app build against these
// signatures; the bodies are placeholders until the render work lands.
//
// Transform contract (the viewer and export must agree exactly):
// - The source frame is scaled so the whole frame fits the canvas
//   (aspect fit), then multiplied by `transform.scale`.
// - `transform.position` is where the centre of the (uncropped) source lands,
//   in canvas units: (0, 0) top left, (1, 1) bottom right.
// - `transform.rotation` is degrees clockwise about that centre.
// - `crop` hides fractions of the source edges without rescaling.
// - Video tracks draw bottom to top: `videoTracks[0]` first.

public struct RenderContext: Sendable {
    public var project: Project
    public var folder: ProjectFolder
    public var analysis: MediaAnalysis?
    /// Use 1080p proxies where they exist (viewer playback). Export never does.
    public var useProxies: Bool
    /// An alternate output format ID, or nil for the main format.
    public var format: String?
    /// Proxies, mattes, isolated voice and loudness. Defaults to `analysis`;
    /// tests and tools can pass files directly.
    public var assets: RenderAssets?
    /// Renders at this size instead of the format's, for example a 1080p
    /// export of a 4K project. Placement is resolution independent.
    public var sizeOverride: CGSize?
    /// Effect definitions, for parameter defaults and Core Image bindings.
    public var effects: EffectRegistry

    public init(
        project: Project,
        folder: ProjectFolder,
        analysis: MediaAnalysis? = nil,
        useProxies: Bool = false,
        format: String? = nil,
        assets: RenderAssets? = nil,
        sizeOverride: CGSize? = nil,
        effects: EffectRegistry = .standard
    ) {
        self.project = project
        self.folder = folder
        self.analysis = analysis
        self.useProxies = useProxies
        self.format = format
        self.assets = assets ?? analysis
        self.sizeOverride = sizeOverride
        self.effects = effects
    }

    /// Output size for the selected format. Always even, as 4:2:0 video
    /// needs.
    public var renderSize: CGSize {
        var size = CGSize(width: project.settings.width, height: project.settings.height)
        if let format, let alt = project.settings.alternateFormats.first(where: { $0.id == format }) {
            size = CGSize(width: alt.width, height: alt.height)
        }
        if let sizeOverride { size = sizeOverride }
        return CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }
}

public struct BuiltComposition: @unchecked Sendable {
    public var composition: AVComposition
    public var videoComposition: AVVideoComposition
    public var audioMix: AVAudioMix
    public var renderSize: CGSize
    public var duration: Time
    /// Things that render differently from the project because something
    /// is missing: a matte or loudness not analysed yet, a missing file.
    public var warnings: [String]

    public init(composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix, renderSize: CGSize, duration: Time, warnings: [String] = []) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.renderSize = renderSize
        self.duration = duration
        self.warnings = warnings
    }

    /// A player item ready for the viewer.
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        // Speed changes keep their pitch, as they do in export.
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

/// Turns a project into an AVFoundation composition with Tandem's compositor.
///
/// Video clips go on composition tracks from a shared pool, alternating
/// A/B wherever a centred transition overlaps two clips; cutout mattes get
/// tracks mirroring their clip. Images, text, solids and adjustment layers
/// are drawn by the compositor. The timeline is split into instructions at
/// every clip and transition boundary, each carrying its layer stack.
public enum CompositionBuilder {
    /// Builds the composition. Media files are opened once and cached, so
    /// rebuilding after an edit is cheap.
    public static func build(_ context: RenderContext) async throws -> BuiltComposition {
        try await CompositionAssembler.build(context)
    }

    /// Blocking version for synchronous callers. Prefer the async one: this
    /// waits on a background task while media files load.
    public static func build(_ context: RenderContext) throws -> BuiltComposition {
        final class Box: @unchecked Sendable { var result: Result<BuiltComposition, Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = .success(try await CompositionAssembler.build(context))
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

/// Renders single frames without a player: API frame grabs, thumbnails of
/// the timeline, golden-frame tests. It goes through the same composition
/// and compositor as export, with RGBA output and zero time tolerance, so
/// the frame is exactly the one at `time`.
public final class FrameRenderer: @unchecked Sendable {
    public let context: RenderContext
    private let lock = NSLock()
    private var prepared: Task<Prepared, Error>?

    /// The composition, and a copy of its video composition using the RGBA
    /// compositor.
    private struct Prepared: @unchecked Sendable {
        var built: BuiltComposition
        var rgb: AVVideoComposition
    }

    public init(context: RenderContext) {
        self.context = context
    }

    /// The frame at `time`, clamped to the timeline. `maxSize` scales it
    /// down to fit, keeping the aspect.
    public func image(at time: Time, maxSize: CGSize? = nil) async throws -> CGImage {
        let prepared = try await composition()
        let built = prepared.built
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = prepared.rgb
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = false
        if let maxSize { generator.maximumSize = maxSize }
        let last = max(.zero, built.duration - context.project.settings.frameRate.frameDuration)
        let (image, _) = try await generator.image(at: min(max(time, .zero), last).cmTime)
        return image
    }

    public func pngData(at time: Time, maxSize: CGSize? = nil) async throws -> Data {
        let image = try await image(at: time, maxSize: maxSize)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw RenderError.compositor("couldn't make a PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.compositor("couldn't make a PNG") }
        return data as Data
    }

    /// Warnings from building the composition, for the API to pass on.
    public func warnings() async throws -> [String] {
        try await composition().built.warnings
    }

    private func composition() async throws -> Prepared {
        let task: Task<Prepared, Error> = lock.withLock {
            if let prepared { return prepared }
            let context = self.context
            let task = Task { () async throws -> Prepared in
                let built = try await CompositionAssembler.build(context)
                let rgb = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
                rgb.customVideoCompositorClass = TandemRGBCompositor.self
                return Prepared(built: built, rgb: rgb)
            }
            prepared = task
            return task
        }
        return try await task.value
    }
}

public struct ExportPreset: Codable, Equatable, Sendable {
    public enum Codec: String, Codable, Sendable { case hevc, h264 }

    public var name: String
    /// Nil keeps the project (or format) size.
    public var width: Int?
    public var height: Int?
    public var codec: Codec
    /// Bits per second.
    public var videoBitrate: Int
    public var audioBitrate: Int
    /// Master loudness; nil leaves the mix as it is.
    public var loudnessTarget: Double?
    public var truePeakCeiling: Double?
    /// Export only this part of the timeline.
    public var range: TimeRange?
    /// Alternate output format ID, for example "portrait".
    public var format: String?

    public init(
        name: String,
        width: Int? = nil,
        height: Int? = nil,
        codec: Codec = .hevc,
        videoBitrate: Int = 80_000_000,
        audioBitrate: Int = 256_000,
        loudnessTarget: Double? = -14,
        truePeakCeiling: Double? = -1,
        range: TimeRange? = nil,
        format: String? = nil
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.codec = codec
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.loudnessTarget = loudnessTarget
        self.truePeakCeiling = truePeakCeiling
        self.range = range
        self.format = format
    }

    public static let youtube4K = ExportPreset(name: "YouTube 4K", codec: .hevc, videoBitrate: 80_000_000)
    public static let youtube1080 = ExportPreset(name: "YouTube 1080p", width: 1920, height: 1080, codec: .h264, videoBitrate: 20_000_000)
    public static let review = ExportPreset(name: "Review 720p", width: 1280, height: 720, codec: .h264, videoBitrate: 5_000_000)
    public static let short = ExportPreset(name: "Short 9:16", codec: .h264, videoBitrate: 20_000_000, format: "portrait")

    public static let all: [ExportPreset] = [.youtube4K, .youtube1080, .review, .short]
}

public struct ExportResult: Codable, Equatable, Sendable {
    public var path: String
    public var duration: Time
    public var integratedLUFS: Double?
    public var truePeakDBTP: Double?
    /// Wall-clock seconds the export took.
    public var elapsed: Double

    public init(path: String, duration: Time, integratedLUFS: Double?, truePeakDBTP: Double?, elapsed: Double) {
        self.path = path
        self.duration = duration
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.elapsed = elapsed
    }
}

/// Renders the timeline to a file.
public final class Exporter: @unchecked Sendable {
    public let context: RenderContext
    public let preset: ExportPreset
    public let output: URL

    public init(context: RenderContext, preset: ExportPreset, output: URL) {
        self.context = context
        self.preset = preset
        self.output = output
    }

    /// `progress` gets 0...1 on an arbitrary queue.
    public func run(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ExportResult {
        throw EditError.notImplemented("Exporter.run")
    }

    public func cancel() {}
}
