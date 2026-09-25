import Foundation
import TandemCore

// Contract for the media module. The signatures here are what the render
// module, the API and the app build against; the bodies are placeholders
// until the media work lands.

/// Finds media in a project folder and describes it.
public enum MediaScanner {
    /// File extensions Tandem treats as media.
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    public static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp"]

    /// Scans the folder for media, skipping `.tandem`, `exports`,
    /// `node_modules` and hidden folders. Known paths keep their IDs; new
    /// files get new items. record-it takes (`<base>-camera.mov` and
    /// `<base>-screen.mov`) share a take ID and carry take offsets.
    public static func scan(_ folder: ProjectFolder, known: [MediaItem]) async throws -> [MediaItem] {
        known
    }

    /// Probes one file: duration, frame rate, size, streams, alpha, VFR.
    public static func probe(_ url: URL, folder: ProjectFolder, id: String? = nil) async throws -> MediaItem {
        throw EditError.notImplemented("MediaScanner.probe")
    }

    /// Guesses what a file is for from its name and folder.
    public static func role(forPath path: String) -> MediaRole {
        let lower = path.lowercased()
        let ext = (lower as NSString).pathExtension
        if lower.hasSuffix("-camera.mov") || lower.contains("camera") { return .camera }
        if lower.hasSuffix("-screen.mov") || lower.contains("screen") { return .screen }
        if lower.contains("/music/") || lower.hasPrefix("music/") { return .music }
        if lower.contains("/sfx/") || lower.hasPrefix("sfx/") { return .sfx }
        if lower.contains("sticker") { return .sticker }
        if lower.contains("graphics") || lower.contains("motion-graphics") { return .graphic }
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .music }
        if lower.contains("broll") || lower.contains("b-roll") { return .broll }
        return .other
    }
}

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
