import CryptoKit
import Foundation

/// Analysis results on disk, one folder per result:
///
///     .tandem/cache/<kind>/<key>/
///       entry.json      what the result is (CacheManifest)
///       ...             the result files (a proxy, a transcript, thumbnails)
///
/// `key = sha256(fingerprint|kind|algorithmVersion|settings)`, so a renamed
/// file finds its results, and a new algorithm version or different
/// settings build new ones.
///
/// Writes are atomic: a job writes into a private `.tmp-` folder beside the
/// entries, then renames it into place with `entry.json` already inside. A
/// crash leaves only a temporary folder, which lookups never see and a later
/// cleanup removes. Entries are evicted least recently used first once the
/// cache passes its size limit.
public final class AnalysisCache: @unchecked Sendable {
    /// 50 GB: a 24 minute 4K take needs about 2 GB of proxy, matte and voice.
    public static let defaultSizeLimit: Int64 = 50 * 1024 * 1024 * 1024
    static let manifestName = "entry.json"
    static let temporaryPrefix = ".tmp-"

    public let root: URL
    private let lock = NSLock()
    private var limit: Int64
    /// Bytes per committed entry ("<kind>/<key>"), loaded on first use.
    private var sizes: [String: Int64]?
    private var touched: [String: Date] = [:]
    private var writing: Set<URL> = []

    public init(root: URL, sizeLimit: Int64 = AnalysisCache.defaultSizeLimit) {
        self.root = root.standardizedFileURL
        self.limit = sizeLimit
    }

    public convenience init(folder: ProjectFolder, sizeLimit: Int64 = AnalysisCache.defaultSizeLimit) {
        self.init(root: folder.cacheFolder, sizeLimit: sizeLimit)
    }

    /// Entries are evicted, least recently used first, once the total size
    /// passes this.
    public var sizeLimit: Int64 {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = newValue } }
    }

    /// The cache key for one analysis of one file.
    public static func key(fingerprint: String, kind: AnalysisKind, algorithmVersion: Int, settings: String) -> String {
        let text = "\(fingerprint)|\(kind.rawValue)|\(algorithmVersion)|\(settings)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func entryURL(kind: AnalysisKind, key: String) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    /// The entry's folder when a complete result exists. Counts as a use for
    /// eviction.
    public func lookup(kind: AnalysisKind, key: String) -> URL? {
        let url = entryURL(kind: kind, key: key)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(Self.manifestName).path) else { return nil }
        markUsed(url, id: "\(kind.rawValue)/\(key)")
        return url
    }

    public func contains(kind: AnalysisKind, key: String) -> Bool {
        FileManager.default.fileExists(atPath: entryURL(kind: kind, key: key).appendingPathComponent(Self.manifestName).path)
    }

    public func manifest(kind: AnalysisKind, key: String) -> CacheManifest? {
        let url = entryURL(kind: kind, key: key).appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CacheManifest.decoder.decode(CacheManifest.self, from: data)
    }

    // MARK: - Writing

    /// A private folder to write one result into, committed or discarded
    /// when the job ends.
    public struct Pending: Sendable {
        public let kind: AnalysisKind
        public let key: String
        /// Write result files here.
        public let folder: URL
    }

    public func begin(kind: AnalysisKind, key: String) throws -> Pending {
        let parent = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        let folder = parent.appendingPathComponent("\(Self.temporaryPrefix)\(key.prefix(16))-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        lock.withLock { _ = writing.insert(folder) }
        return Pending(kind: kind, key: key, folder: folder)
    }

    /// Moves a finished result into place and returns its folder. If another
    /// job committed the same key first, that result is kept and this one
    /// thrown away.
    @discardableResult
    public func commit(_ pending: Pending, fingerprint: String, algorithmVersion: Int, settings: String, source: String) throws -> URL {
        defer { lock.withLock { _ = writing.remove(pending.folder) } }
        let files = try Self.files(in: pending.folder)
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        let manifest = CacheManifest(
            kind: pending.kind, key: pending.key, fingerprint: fingerprint, algorithmVersion: algorithmVersion,
            settings: settings, source: source, created: Date(), bytes: bytes, files: files.map(\.name).sorted()
        )
        try CacheManifest.encoder.encode(manifest).write(to: pending.folder.appendingPathComponent(Self.manifestName))

        let destination = entryURL(kind: pending.kind, key: pending.key)
        if Foundation.rename(pending.folder.path, destination.path) != 0 {
            let error = errno
            if contains(kind: pending.kind, key: pending.key) {
                try? FileManager.default.removeItem(at: pending.folder)
                return destination
            }
            if error == ENOTEMPTY || error == EEXIST {
                // A broken entry without a manifest: replace it.
                Self.delete(destination)
                if Foundation.rename(pending.folder.path, destination.path) != 0 {
                    throw MediaError.failed("Couldn't store the \(pending.kind.rawValue) result (\(String(cString: strerror(errno))))")
                }
            } else {
                throw MediaError.failed("Couldn't store the \(pending.kind.rawValue) result (\(String(cString: strerror(error))))")
            }
        }
        lock.withLock {
            sizes?["\(pending.kind.rawValue)/\(pending.key)"] = bytes + Int64(manifestSize(destination))
        }
        evictIfNeeded(keeping: ["\(pending.kind.rawValue)/\(pending.key)"])
        return destination
    }

    public func discard(_ pending: Pending) {
        try? FileManager.default.removeItem(at: pending.folder)
        lock.withLock { _ = writing.remove(pending.folder) }
    }

    public func remove(kind: AnalysisKind, key: String) {
        Self.delete(entryURL(kind: kind, key: key))
        lock.withLock { _ = sizes?.removeValue(forKey: "\(kind.rawValue)/\(key)") }
    }

    /// Renames an entry out of the way before deleting it, so a lookup never
    /// sees a manifest whose files are half gone.
    static func delete(_ entry: URL) {
        let doomed = entry.deletingLastPathComponent().appendingPathComponent("\(temporaryPrefix)evicted-\(UUID().uuidString)", isDirectory: true)
        if Foundation.rename(entry.path, doomed.path) == 0 {
            try? FileManager.default.removeItem(at: doomed)
        } else {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Size and eviction

    /// Total bytes of committed entries.
    public var totalSize: Int64 {
        lock.withLock { loadSizes().values.reduce(0, +) }
    }

    /// Removes least recently used entries until the cache fits its limit.
    /// Returns the removed entries as "<kind>/<key>".
    @discardableResult
    public func evictIfNeeded(keeping: Set<String> = []) -> [String] {
        let (limit, total) = lock.withLock { (self.limit, loadSizes().values.reduce(0, +)) }
        guard total > limit else { return [] }
        var removed: [String] = []
        var remaining = total
        for entry in entriesByLastUse() where remaining > limit {
            guard !keeping.contains(entry.id) else { continue }
            Self.delete(entry.url)
            remaining -= entry.bytes
            removed.append(entry.id)
            lock.withLock { _ = sizes?.removeValue(forKey: entry.id) }
        }
        return removed
    }

    /// Deletes temporary folders left by crashed jobs.
    public func removeStaleTemporaryFolders(olderThan age: TimeInterval = 3600) {
        let active = lock.withLock { writing }
        let cutoff = Date().addingTimeInterval(-age)
        for kind in AnalysisKind.allCases {
            let parent = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { continue }
            for name in names where name.hasPrefix(Self.temporaryPrefix) {
                let url = parent.appendingPathComponent(name, isDirectory: true)
                guard !active.contains(url) else { continue }
                // A long build in another process keeps writing its file, so
                // the newest date inside says whether anyone is still at it.
                if Self.lastModified(url) < cutoff { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    struct EntryInfo {
        var id: String
        var url: URL
        var bytes: Int64
        var lastUse: Date
    }

    /// Committed entries, least recently used first.
    func entriesByLastUse() -> [EntryInfo] {
        var entries: [EntryInfo] = []
        for kind in AnalysisKind.allCases {
            let parent = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let url = parent.appendingPathComponent(name, isDirectory: true)
                let id = "\(kind.rawValue)/\(name)"
                let bytes = lock.withLock { sizes?[id] } ?? Self.folderSize(url)
                let lastUse = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                entries.append(EntryInfo(id: id, url: url, bytes: bytes, lastUse: lastUse))
            }
        }
        return entries.sorted { $0.lastUse == $1.lastUse ? $0.id < $1.id : $0.lastUse < $1.lastUse }
    }

    /// Call with the lock held.
    private func loadSizes() -> [String: Int64] {
        if let sizes { return sizes }
        var loaded: [String: Int64] = [:]
        for kind in AnalysisKind.allCases {
            let parent = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                loaded["\(kind.rawValue)/\(name)"] = Self.folderSize(parent.appendingPathComponent(name, isDirectory: true))
            }
        }
        sizes = loaded
        return loaded
    }

    /// Bumps the entry's folder date, which eviction reads as its last use.
    /// At most once a minute per entry, to keep lookups cheap.
    private func markUsed(_ url: URL, id: String) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            if let last = touched[id], now.timeIntervalSince(last) < 60 { return false }
            touched[id] = now
            return true
        }
        if due { try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path) }
    }

    private func manifestSize(_ folder: URL) -> Int {
        (try? folder.appendingPathComponent(Self.manifestName).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    static func files(in folder: URL) throws -> [(name: String, size: Int64)] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [] }
        var files: [(String, Int64)] = []
        let base = folder.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            files.append((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent, Int64(values.fileSize ?? 0)))
        }
        return files
    }

    /// The newest modification date of a folder or anything in it.
    static func lastModified(_ folder: URL) -> Date {
        let key = URLResourceKey.contentModificationDateKey
        var newest = (try? folder.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [key]) {
            for case let url as URL in enumerator {
                if let date = (try? url.resourceValues(forKeys: [key]))?.contentModificationDate, date > newest { newest = date }
            }
        }
        return newest
    }

    static func folderSize(_ folder: URL) -> Int64 {
        ((try? files(in: folder)) ?? []).reduce(0) { $0 + $1.size }
    }
}

/// What a cache entry holds, written as `entry.json` in its folder.
public struct CacheManifest: Codable, Equatable, Sendable {
    public var kind: AnalysisKind
    public var key: String
    public var fingerprint: String
    public var algorithmVersion: Int
    /// The settings the result was made with, as canonical JSON.
    public var settings: String
    /// The file's path when the result was made, for people reading the cache.
    public var source: String
    public var created: Date
    /// Bytes of the result files.
    public var bytes: Int64
    public var files: [String]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
