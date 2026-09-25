import AVFoundation
import Foundation
import TandemCore

/// Background analysis for one project folder: thumbnails, waveforms,
/// loudness, proxies, transcripts, cutout mattes and isolated voice. Results
/// are cached under `.tandem/cache`, keyed by the file's fingerprint, the
/// analysis kind, its algorithm version and its settings, so they survive
/// renames and are rebuilt when the algorithm changes.
///
/// Reads (`transcript(for:)`, `proxyURL(for:)`...) are synchronous and only
/// look at the cache: nil means "not made yet". `request` and
/// `requestDefaults` queue the work; `observe` reports progress.
public final class MediaAnalysis: @unchecked Sendable {
    public let folder: ProjectFolder
    public let cache: AnalysisCache
    let scheduler: JobScheduler

    private let lock = NSLock()
    private var storedSettings: AnalysisSettings
    /// Fingerprints computed for items that didn't carry one, by path.
    private var fingerprints: [String: (stat: FileStat, value: String)] = [:]
    /// Decoded transcripts and waveforms, by cache key.
    private let decoded = NSCache<NSString, DecodedResult>()

    public convenience init(folder: ProjectFolder) {
        self.init(folder: folder, settings: .standard)
    }

    /// - Parameters:
    ///   - encoderLock: shared with exports so they take turns on the
    ///     hardware encoder. Tests pass their own.
    public init(folder: ProjectFolder, settings: AnalysisSettings = .standard, cacheSizeLimit: Int64 = AnalysisCache.defaultSizeLimit, encoderLock: EncoderLock = .shared) {
        self.folder = folder
        storedSettings = settings
        cache = AnalysisCache(folder: folder, sizeLimit: cacheSizeLimit)
        scheduler = JobScheduler(encoderLock: encoderLock)
        decoded.countLimit = 64
        // Leftovers from a crash; never touches anything being written now.
        let cache = self.cache
        DispatchQueue.global(qos: .background).async { cache.removeStaleTemporaryFolders() }
    }

    /// How analyses are made. Changing a setting makes the affected kinds
    /// look uncached (their keys change); request them again to rebuild.
    public var settings: AnalysisSettings {
        get { lock.withLock { storedSettings } }
        set { lock.withLock { storedSettings = newValue } }
    }

    // MARK: - Cached results

    public func transcript(for item: MediaItem) -> Transcript? {
        decodedResult(.transcript, for: item) { TranscriptJob.read(from: $0) }
    }

    public func waveform(for item: MediaItem) -> Waveform? {
        decodedResult(.waveform, for: item) { WaveformJob.read(from: $0) }
    }

    public func loudness(for item: MediaItem) -> Loudness? {
        entryFolder(.loudness, for: item).flatMap { LoudnessJob.read(from: $0) }
    }

    /// The strip and the folder its files are relative to.
    public func thumbnails(for item: MediaItem) -> (strip: ThumbnailStrip, folder: URL)? {
        guard let folder = entryFolder(.thumbnails, for: item), let strip = ThumbnailJob.read(from: folder) else { return nil }
        return (strip, folder)
    }

    /// 1080p all-intra HEVC with the source's exact frame times (video only).
    public func proxyURL(for item: MediaItem) -> URL? {
        entryFolder(.proxy, for: item)?.appendingPathComponent(ProxyJob.file)
    }

    /// Greyscale HEVC matte with the source's exact frame times: the luma
    /// of full-range frames is the alpha (0 background, 255 person).
    public func matteURL(for item: MediaItem) -> URL? {
        entryFolder(.matte, for: item)?.appendingPathComponent(MatteJob.file)
    }

    /// The matte made in a particular mode, if it has been.
    public func matteURL(for item: MediaItem, mode: CutoutMode) -> URL? {
        var settings = self.settings
        settings.matteMode = mode
        return entryFolder(.matte, for: item, settings: settings)?.appendingPathComponent(MatteJob.file)
    }

    /// 48 kHz ALAC, same length as the source audio and lined up to the
    /// sample (the unit's latency is already removed).
    public func isolatedVoiceURL(for item: MediaItem) -> URL? {
        entryFolder(.isolatedVoice, for: item)?.appendingPathComponent(IsolatedVoiceJob.file)
    }

    public func isCached(_ kind: AnalysisKind, for item: MediaItem) -> Bool {
        guard let key = cacheKey(kind, for: item) else { return false }
        return cache.contains(kind: kind, key: key)
    }

    /// The cache key for one analysis of one item, or nil when the file
    /// can't be read.
    public func cacheKey(_ kind: AnalysisKind, for item: MediaItem, settings: AnalysisSettings? = nil) -> String? {
        guard let fingerprint = fingerprint(for: item) else { return nil }
        let settings = settings ?? self.settings
        return AnalysisCache.key(fingerprint: fingerprint, kind: kind, algorithmVersion: kind.algorithmVersion, settings: settings.canonical(for: kind))
    }

    // MARK: - Requests

    /// Queues one analysis. Cheap if the result is already cached.
    public func request(_ kind: AnalysisKind, for item: MediaItem, priority: JobPriority = .background) {
        submit(kind, for: item, priority: priority)
    }

    /// Queues one analysis and returns its job ID, or nil when there's
    /// nothing to do (cached, not applicable or unreadable).
    ///
    /// - Parameter settings: make it with other settings than the current
    ///   ones, for example a `.person` matte for a clip whose cutout mode
    ///   asks for one (read it back with `matteURL(for:mode:)`).
    @discardableResult
    public func submit(_ kind: AnalysisKind, for item: MediaItem, priority: JobPriority = .background, settings: AnalysisSettings? = nil) -> String? {
        guard kind.applies(to: item), let fingerprint = fingerprint(for: item) else { return nil }
        let settings = settings ?? self.settings
        let canonical = settings.canonical(for: kind)
        let key = AnalysisCache.key(fingerprint: fingerprint, kind: kind, algorithmVersion: kind.algorithmVersion, settings: canonical)
        guard !cache.contains(kind: kind, key: key) else { return nil }
        let source = folder.url(for: item)
        let cache = self.cache
        let job = JobScheduler.Job(id: Self.jobID(kind, key: key), kind: kind, mediaID: item.id, priority: priority) { context in
            try await Self.make(kind, item: item, source: source, fingerprint: fingerprint, key: key, settings: settings, cache: cache, context: context)
        }
        return scheduler.submit(job)
    }

    /// Queues the usual analyses for a set of media, timeline media first:
    /// thumbnails, waveform and loudness for everything they apply to, a
    /// proxy for video bigger than the proxy size, and a transcript, matte
    /// and isolated voice for camera files.
    public func requestDefaults(for items: [MediaItem], usedOnTimeline: Set<String>) {
        let settings = self.settings
        let ordered = items.filter { usedOnTimeline.contains($0.id) } + items.filter { !usedOnTimeline.contains($0.id) }
        for item in ordered {
            let priority: JobPriority = usedOnTimeline.contains(item.id) ? .timeline : .background
            for kind in Self.defaultKinds(for: item, settings: settings) {
                submit(kind, for: item, priority: priority)
            }
        }
    }

    /// The analyses `requestDefaults` asks for.
    public static func defaultKinds(for item: MediaItem, settings: AnalysisSettings = .standard) -> [AnalysisKind] {
        var kinds: [AnalysisKind] = [.thumbnails, .waveform, .loudness].filter { $0.applies(to: item) }
        if item.kind == .video, item.hasVideo, let width = item.width, let height = item.height {
            let fitted = fittedSize(width: width, height: height, maxWidth: settings.proxyMaxWidth, maxHeight: settings.proxyMaxHeight)
            if fitted.width < width || fitted.height < height { kinds.append(.proxy) }
        }
        if item.role == .camera {
            kinds += [AnalysisKind.transcript, .isolatedVoice, .matte].filter { $0.applies(to: item) }
        }
        return kinds
    }

    /// Requests an analysis (if needed) and waits for it to finish.
    @discardableResult
    public func waitFor(_ kind: AnalysisKind, for item: MediaItem, priority: JobPriority = .interactive, settings: AnalysisSettings? = nil) async -> ResultState {
        if let id = submit(kind, for: item, priority: priority, settings: settings) {
            _ = await scheduler.wait(for: id)
        }
        return state(kind, for: item, settings: settings)
    }

    /// Where one analysis of one item stands.
    public func state(_ kind: AnalysisKind, for item: MediaItem, settings: AnalysisSettings? = nil) -> ResultState {
        guard kind.applies(to: item) else { return .notApplicable }
        guard let key = cacheKey(kind, for: item, settings: settings) else { return .unreadable }
        if cache.contains(kind: kind, key: key) { return .ready }
        guard let status = scheduler.status(id: Self.jobID(kind, key: key)) else { return .missing }
        switch status.state {
        case .queued: return .queued
        case .running: return .running(progress: status.progress)
        case .done: return cache.contains(kind: kind, key: key) ? .ready : .missing
        case .failed: return .failed(status.message ?? "failed")
        case .cancelled: return .missing
        }
    }

    public var jobs: [JobStatus] { scheduler.statuses }

    /// Called on an arbitrary queue whenever job status changes.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable ([JobStatus]) -> Void) -> UUID {
        scheduler.observe(handler)
    }

    public func removeObserver(_ token: UUID) {
        scheduler.removeObserver(token)
    }

    public func cancelAll() {
        scheduler.cancelAll()
    }

    public func cancel(jobID: String) {
        scheduler.cancel(id: jobID)
    }

    /// Cancels every job for one media item, for example when it's removed.
    public func cancelJobs(for mediaID: String) {
        scheduler.cancel(mediaID: mediaID)
    }

    // MARK: - Internals

    static func jobID(_ kind: AnalysisKind, key: String) -> String {
        "\(kind.rawValue)-\(key.prefix(16))"
    }

    /// Makes one analysis into a private folder and commits it, checking the
    /// file didn't change underneath.
    static func make(_ kind: AnalysisKind, item: MediaItem, source: URL, fingerprint: String, key: String, settings: AnalysisSettings, cache: AnalysisCache, context: JobContext) async throws {
        guard let expected = Fingerprint(fingerprint), expected.matchesStat(of: source) else {
            throw MediaError.fileChanged(item.path)
        }
        let pending = try cache.begin(kind: kind, key: key)
        do {
            try await AnalysisJobs.run(kind, source: source, item: item, settings: settings, into: pending.folder, context: context)
            try context.checkCancellation()
            guard expected.matchesStat(of: source) else { throw MediaError.fileChanged(item.path) }
            try cache.commit(pending, fingerprint: fingerprint, algorithmVersion: kind.algorithmVersion, settings: settings.canonical(for: kind), source: item.path)
        } catch {
            cache.discard(pending)
            throw error
        }
    }

    private func entryFolder(_ kind: AnalysisKind, for item: MediaItem, settings: AnalysisSettings? = nil) -> URL? {
        guard let key = cacheKey(kind, for: item, settings: settings) else { return nil }
        return cache.lookup(kind: kind, key: key)
    }

    private func decodedResult<T>(_ kind: AnalysisKind, for item: MediaItem, _ load: (URL) -> T?) -> T? {
        guard let key = cacheKey(kind, for: item), let folder = cache.lookup(kind: kind, key: key) else { return nil }
        let memoKey = "\(kind.rawValue)/\(key)" as NSString
        if let hit = decoded.object(forKey: memoKey)?.value as? T { return hit }
        guard let value = load(folder) else { return nil }
        decoded.setObject(DecodedResult(value), forKey: memoKey)
        return value
    }

    /// The item's fingerprint, or one computed from the file (remembered
    /// while the file's size and date don't change).
    func fingerprint(for item: MediaItem) -> String? {
        if let stored = item.fingerprint, Fingerprint(stored) != nil { return stored }
        let url = folder.url(for: item)
        guard let stat = try? FileStat(url) else { return nil }
        if let known = lock.withLock({ fingerprints[item.path] }), known.stat == stat { return known.value }
        guard let computed = try? Fingerprint.compute(for: url).description else { return nil }
        lock.withLock { fingerprints[item.path] = (stat, computed) }
        return computed
    }
}

extension MediaAnalysis {
    /// Where one analysis of one media item stands. (Nested because the API
    /// module has its own `AnalysisState` for JSON.)
    public enum ResultState: Equatable, Sendable {
        /// The kind doesn't apply (a matte for audio, a waveform for silence).
        case notApplicable
        /// The file can't be read.
        case unreadable
        /// Not made and not queued.
        case missing
        case queued
        case running(progress: Double)
        case ready
        case failed(String)
    }
}

private final class DecodedResult {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Runs one kind of analysis into a folder.
enum AnalysisJobs {
    static func run(_ kind: AnalysisKind, source: URL, item: MediaItem, settings: AnalysisSettings, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws {
        switch kind {
        case .thumbnails:
            try await ThumbnailJob.run(source: source, kind: item.kind, interval: settings.thumbnailInterval, width: settings.thumbnailWidth, into: folder, context: context, timeRange: timeRange)
        case .waveform:
            try await WaveformJob.run(source: source, rate: settings.waveformRate, into: folder, context: context, timeRange: timeRange)
        case .loudness:
            try await LoudnessJob.run(source: source, into: folder, context: context, timeRange: timeRange)
        case .proxy:
            try await ProxyJob.run(source: source, settings: settings, into: folder, context: context, timeRange: timeRange)
        case .transcript:
            try await TranscriptJob.run(source: source, locale: settings.transcriptLocale, into: folder, context: context, timeRange: timeRange)
        case .matte:
            try await MatteJob.run(source: source, settings: settings, into: folder, context: context, timeRange: timeRange)
        case .isolatedVoice:
            try await IsolatedVoiceJob.run(source: source, model: settings.voiceModel, into: folder, context: context, timeRange: timeRange)
        }
    }
}
