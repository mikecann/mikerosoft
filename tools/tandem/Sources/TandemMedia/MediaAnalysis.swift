import Foundation
import TandemCore

/// Background analysis for one project folder: thumbnails, waveforms,
/// loudness, proxies, transcripts, cutout mattes and isolated voice. Results
/// are cached under `.tandem/cache`, keyed by the file's fingerprint, the
/// analysis kind, its algorithm version and its settings, so they survive
/// renames and are rebuilt when the algorithm changes.
public final class MediaAnalysis: @unchecked Sendable {
    public let folder: ProjectFolder

    public init(folder: ProjectFolder) {
        self.folder = folder
    }

    public func transcript(for item: MediaItem) -> Transcript? { nil }
    public func waveform(for item: MediaItem) -> Waveform? { nil }
    public func loudness(for item: MediaItem) -> Loudness? { nil }
    /// The strip and the folder its files are relative to.
    public func thumbnails(for item: MediaItem) -> (strip: ThumbnailStrip, folder: URL)? { nil }
    public func proxyURL(for item: MediaItem) -> URL? { nil }
    public func matteURL(for item: MediaItem) -> URL? { nil }
    public func isolatedVoiceURL(for item: MediaItem) -> URL? { nil }

    /// Queues one analysis. Cheap if the result is already cached.
    public func request(_ kind: AnalysisKind, for item: MediaItem, priority: JobPriority = .background) {}

    /// Queues the usual analyses for a set of media, timeline media first.
    public func requestDefaults(for items: [MediaItem], usedOnTimeline: Set<String>) {}

    public var jobs: [JobStatus] { [] }

    /// Called on an arbitrary queue whenever job status changes.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable ([JobStatus]) -> Void) -> UUID { UUID() }

    public func removeObserver(_ token: UUID) {}

    public func cancelAll() {}
}
