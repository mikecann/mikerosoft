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

    public init(project: Project, folder: ProjectFolder, analysis: MediaAnalysis? = nil, useProxies: Bool = false, format: String? = nil) {
        self.project = project
        self.folder = folder
        self.analysis = analysis
        self.useProxies = useProxies
        self.format = format
    }

    /// Output size for the selected format.
    public var renderSize: CGSize {
        if let format, let alt = project.settings.alternateFormats.first(where: { $0.id == format }) {
            return CGSize(width: alt.width, height: alt.height)
        }
        return CGSize(width: project.settings.width, height: project.settings.height)
    }
}

public struct BuiltComposition: @unchecked Sendable {
    public var composition: AVComposition
    public var videoComposition: AVVideoComposition
    public var audioMix: AVAudioMix
    public var renderSize: CGSize
    public var duration: Time

    public init(composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix, renderSize: CGSize, duration: Time) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.renderSize = renderSize
        self.duration = duration
    }

    /// A player item ready for the viewer.
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

/// Turns a project into an AVFoundation composition with Tandem's compositor.
public enum CompositionBuilder {
    public static func build(_ context: RenderContext) throws -> BuiltComposition {
        throw EditError.notImplemented("CompositionBuilder.build")
    }
}

/// Renders single frames without a player: API frame grabs, thumbnails of
/// the timeline, golden-frame tests.
public final class FrameRenderer: @unchecked Sendable {
    public let context: RenderContext

    public init(context: RenderContext) {
        self.context = context
    }

    public func image(at time: Time, maxSize: CGSize? = nil) async throws -> CGImage {
        throw EditError.notImplemented("FrameRenderer.image")
    }

    public func pngData(at time: Time, maxSize: CGSize? = nil) async throws -> Data {
        throw EditError.notImplemented("FrameRenderer.pngData")
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
