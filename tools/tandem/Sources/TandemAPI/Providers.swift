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

/// Frame grabs and exports. The default goes through `FrameRenderer` and
/// `Exporter`; tests inject a fake so the API plumbing (files, base64, MCP
/// image content, progress events) is tested without the render module.
public protocol RenderBackend: Sendable {
    func pngData(context: RenderContext, at time: Time, maxSize: CGSize?) async throws -> Data
    func export(
        context: RenderContext,
        preset: ExportPreset,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult
}

public struct DefaultRenderBackend: RenderBackend {
    public init() {}

    public func pngData(context: RenderContext, at time: Time, maxSize: CGSize?) async throws -> Data {
        try await FrameRenderer(context: context).pngData(at: time, maxSize: maxSize)
    }

    public func export(
        context: RenderContext,
        preset: ExportPreset,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        try await Exporter(context: context, preset: preset, output: output).run(progress: progress)
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
