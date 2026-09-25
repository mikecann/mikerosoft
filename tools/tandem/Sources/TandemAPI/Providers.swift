import CoreGraphics
import Foundation
import TandemCore
import TandemMedia
import TandemRender

/// Where the service reads analysis results from. `MediaAnalysis` is the
/// real one; tests inject a fake so transcript tools can be tested without
/// the media module.
public protocol AnalysisSource: AnyObject, Sendable {
    func transcript(for item: MediaItem) -> Transcript?
    func loudness(for item: MediaItem) -> Loudness?
    /// True when a result for `kind` is cached and ready to use.
    func isReady(_ kind: AnalysisKind, for item: MediaItem) -> Bool
    var jobs: [JobStatus] { get }
    /// Calls `handler` whenever job status changes. Returns a token for
    /// `removeJobsObserver`.
    func observeJobs(_ handler: @escaping @Sendable ([JobStatus]) -> Void) -> UUID
    func removeJobsObserver(_ token: UUID)
}

/// The real analysis, through `MediaAnalysis`'s documented methods. An
/// adapter rather than an extension, so nothing here can clash with names
/// the media module adds.
public final class MediaAnalysisSource: AnalysisSource, @unchecked Sendable {
    public let analysis: MediaAnalysis

    public init(_ analysis: MediaAnalysis) {
        self.analysis = analysis
    }

    public func transcript(for item: MediaItem) -> Transcript? { analysis.transcript(for: item) }
    public func loudness(for item: MediaItem) -> Loudness? { analysis.loudness(for: item) }

    public func isReady(_ kind: AnalysisKind, for item: MediaItem) -> Bool {
        analysis.isCached(kind, for: item)
    }

    public var jobs: [JobStatus] { analysis.jobs }

    public func observeJobs(_ handler: @escaping @Sendable ([JobStatus]) -> Void) -> UUID {
        analysis.observe(handler)
    }

    public func removeJobsObserver(_ token: UUID) {
        analysis.removeObserver(token)
    }
}

/// A rendered frame and what the renderer couldn't do as the project asks.
public struct RenderedFrame: Sendable {
    public var png: Data
    /// For example "No cutout matte for source/take-camera.mov yet, showing
    /// the full frame."
    public var warnings: [String]

    public init(png: Data, warnings: [String] = []) {
        self.png = png
        self.warnings = warnings
    }
}

/// A finished export and the renderer's warnings for what it rendered.
public struct RenderedExport: Sendable {
    public var result: ExportResult
    public var warnings: [String]

    public init(result: ExportResult, warnings: [String] = []) {
        self.result = result
        self.warnings = warnings
    }
}

/// Frame grabs and exports. The default goes through `FrameRenderer` and
/// `Exporter`; tests inject a fake so the API plumbing (files, base64, MCP
/// image content, progress events, warnings) is tested without rendering.
public protocol RenderBackend: Sendable {
    func frame(context: RenderContext, at time: Time, maxSize: CGSize?) async throws -> RenderedFrame
    func export(
        context: RenderContext,
        preset: ExportPreset,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedExport
}

public struct DefaultRenderBackend: RenderBackend {
    public init() {}

    public func frame(context: RenderContext, at time: Time, maxSize: CGSize?) async throws -> RenderedFrame {
        let renderer = FrameRenderer(context: context)
        let png = try await renderer.pngData(at: time, maxSize: maxSize)
        // The composition is built by now, so this costs nothing.
        let warnings = (try? await renderer.warnings()) ?? []
        return RenderedFrame(png: png, warnings: warnings)
    }

    public func export(
        context: RenderContext,
        preset: ExportPreset,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedExport {
        // The exporter builds its own composition and keeps its warnings to
        // itself, so build one alongside it just to read them.
        async let warnings = (try? await CompositionBuilder.build(context).warnings) ?? []
        let result = try await Exporter(context: context, preset: preset, output: output).run(progress: progress)
        return RenderedExport(result: result, warnings: await warnings)
    }
}

/// Picks the render warnings that matter for part of the timeline. The
/// renderer warns about the whole project (every file still missing its
/// cutout matte, say), so a frame at 2:00 only keeps the lines about media
/// and clips that play around then. Lines that name no media or clip are
/// always kept. Repeats are dropped.
public enum RenderWarnings {
    public static func relevant(_ warnings: [String], in project: Project, range: TimeRange?) -> [String] {
        var seen = Set<String>()
        let unique = warnings.filter { seen.insert($0).inserted }
        guard let range else { return unique }
        let clips = project.allTracks.flatMap(\.clips)
        let playing = clips.filter { $0.range.overlaps(range) }
        let playingIDs = Set(playing.map(\.id))
        let playingMedia = Set(playing.compactMap(\.mediaID))
        let paths = project.media.map { ($0.id, $0.path) }
        return unique.filter { line in
            let mentionedClips = clips.map(\.id).filter { line.contains($0) }
            let mentionedMedia = paths.filter { line.contains($0.1) }.map(\.0)
            if mentionedClips.isEmpty && mentionedMedia.isEmpty { return true }
            return mentionedClips.contains(where: playingIDs.contains) || mentionedMedia.contains(where: playingMedia.contains)
        }
    }
}

/// Export presets by name, forgiving about case, spaces and punctuation, so
/// `youtube4k`, `YouTube 4K` and `youtube-4k` all work, and `review` and
/// `short` find their presets.
public enum PresetNames {
    public static func find(_ name: String) -> ExportPreset? {
        let wanted = slug(name)
        return ExportPreset.all.first { slug($0.name) == wanted || slug($0.name).hasPrefix(wanted) }
    }

    /// A short name for the CLI: `youtube4k`, `youtube1080p`, `review720p`, `short916`.
    public static func short(_ preset: ExportPreset) -> String { slug(preset.name) }

    static func slug(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
