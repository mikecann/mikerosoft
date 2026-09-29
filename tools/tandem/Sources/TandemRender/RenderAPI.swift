import AVFoundation
import CoreGraphics
import Foundation
import TandemCore
import TandemMedia

// Contract for the render module. The API and the app build against these
// signatures; the work happens in the rest of the module (see
// docs/RENDER.md), and `LayerMath` has the placement maths for the viewer.
//
// Transform contract (the viewer and export must agree exactly):
// - The source frame is scaled so the whole frame fits the canvas
//   (aspect fit), then multiplied by `transform.scale`.
// - `transform.position` is where the centre of the (uncropped) source lands,
//   in canvas units: (0, 0) top left, (1, 1) bottom right.
// - `transform.rotation` is degrees clockwise about that centre.
// - `crop` hides fractions of the source edges without rescaling.
// - Opacity multiplies the layer, its shadow included, and the cutout matte
//   is applied before the shadow, so the shadow follows the person.
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
    /// The viewer's drag previews, read by the player on every frame.
    public var liveOverrides: LiveVideoOverrides?

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
///
/// It builds the composition once, from the project and the proxies and
/// mattes that exist then. Make a new one when either changes: one kept
/// past a finished matte renders that clip without its cutout. Files macOS
/// can't decode are converted before it builds (`ConvertedMedia`).
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
                let (ready, notes) = await ConvertedMedia.prepare(context)
                var built = try await CompositionAssembler.build(ready)
                built.warnings = notes + built.warnings
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

/// How an export is encoded. A preset sets the quality and the project sets
/// the shape: `plan(for:)` (ExportPlan.swift) works out the frame, size and
/// bitrate for a project, and the exporter renders that plan.
public struct ExportPreset: Codable, Equatable, Sendable {
    public enum Codec: String, Codable, Sendable {
        case hevc, h264

        /// As people write it.
        public var displayName: String { self == .hevc ? "HEVC" : "H.264" }
    }

    public var name: String
    /// An exact frame size. Nil leaves the size to `resolution`, or keeps
    /// the canvas (or format) size when that's nil too.
    public var width: Int?
    public var height: Int?
    /// The resolution class: the frame's short side in pixels, 2160 for 4K
    /// and 1080 for 1080p. The frame keeps the canvas's shape, so 1080 is
    /// 1920x1080 on a landscape canvas and 1080x1920 on a 9:16 one.
    public var resolution: Int?
    public var codec: Codec
    /// Bits per second. With a `resolution` this is the rate for a 16:9
    /// frame of that class at up to 30 fps, and the plan scales it to the
    /// frame's area and frame rate.
    public var videoBitrate: Int
    public var audioBitrate: Int
    /// Master loudness; nil leaves the mix as it is.
    public var loudnessTarget: Double?
    public var truePeakCeiling: Double?
    /// Export only this part of the timeline.
    public var range: TimeRange?
    /// Alternate output format ID, for example "portrait", or "main" for
    /// the canvas. "portrait" on a project whose own canvas is 9:16 renders
    /// that canvas: the project is its own short.
    public var format: String?

    public init(
        name: String,
        width: Int? = nil,
        height: Int? = nil,
        resolution: Int? = nil,
        codec: Codec = .hevc,
        videoBitrate: Int = 80_000_000,
        audioBitrate: Int = 320_000,
        loudnessTarget: Double? = -14,
        truePeakCeiling: Double? = -1,
        range: TimeRange? = nil,
        format: String? = nil
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.resolution = resolution
        self.codec = codec
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.loudnessTarget = loudnessTarget
        self.truePeakCeiling = truePeakCeiling
        self.range = range
        self.format = format
    }

    // Checked against YouTube's recommended upload settings in September
    // 2026: 8 Mbps for 1080p and 35 to 45 for 4K at 24 to 30 fps, half as
    // much again at 48 to 60 fps, all H.264. 20 Mbps is 2.5 times YouTube's
    // 1080p rate, and HEVC at 80 is about as generous for 4K, since HEVC
    // needs roughly a third fewer bits than H.264 for the same picture.
    // That's the headroom a speed-priority hardware encoder and YouTube's
    // own re-encode want, and it's what Mike's Filmora presets used. The
    // plan adds YouTube's half again for high frame rates. YouTube asks
    // for 384 kbps AAC stereo, more than Apple's AAC encoder takes at
    // 48 kHz, so audio gets the most it takes: 320.
    public static let youtube4K = ExportPreset(name: "YouTube 4K", resolution: 2160, codec: .hevc, videoBitrate: 80_000_000)
    public static let youtube1080 = ExportPreset(name: "YouTube 1080p", resolution: 1080, codec: .h264, videoBitrate: 20_000_000)
    public static let review = ExportPreset(name: "Review 720p", resolution: 720, codec: .h264, videoBitrate: 5_000_000)
    public static let short = ExportPreset(name: "Short 9:16", resolution: 1080, codec: .h264, videoBitrate: 20_000_000, format: OutputFormat.portrait.id)

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
///
/// Frames come from the same compositor as the viewer, encoded by the
/// hardware VideoToolbox encoder at speed priority and the preset's
/// bitrate, tagged BT.709 video range. The mix is measured first and
/// mastered to `loudnessTarget` under `truePeakCeiling` (a lookahead
/// true-peak limiter), then encoded as AAC, 48 kHz stereo. The preset's
/// loudness values are used as given; nil leaves the mix alone. A snapshot
/// of the project is written beside the file as `<output>.tandem`.
public final class Exporter: @unchecked Sendable {
    public let context: RenderContext
    public let preset: ExportPreset
    public let output: URL
    private let lock = NSLock()
    private var job: ExportPipeline?
    private var cancelRequested = false

    /// What rendered differently from the project (a cutout matte not made
    /// yet, a sticker that couldn't be converted), once `run` has built the
    /// composition.
    public var warnings: [String] { lock.withLock { job }?.warnings ?? [] }

    public init(context: RenderContext, preset: ExportPreset, output: URL) {
        self.context = context
        self.preset = preset
        self.output = output
    }

    /// `progress` gets 0...1 on an arbitrary queue. Throws
    /// `RenderError.cancelled` after `cancel()` or task cancellation, and
    /// removes the partial file.
    public func run(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ExportResult {
        let job = ExportPipeline(context: context, preset: preset, output: output, progress: progress)
        let cancelled = lock.withLock {
            self.job = job
            return cancelRequested
        }
        if cancelled { throw RenderError.cancelled }
        return try await withTaskCancellationHandler {
            try await job.run()
        } onCancel: {
            job.cancel()
        }
    }

    public func cancel() {
        let job: ExportPipeline? = lock.withLock {
            cancelRequested = true
            return self.job
        }
        job?.cancel()
    }
}
