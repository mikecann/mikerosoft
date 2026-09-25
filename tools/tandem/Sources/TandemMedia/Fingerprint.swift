import CryptoKit
import Foundation

/// A cheap identity for a media file: its size, modification time and a
/// SHA-256 of its first and last megabyte.
///
/// Written into `MediaItem.fingerprint` as `<size>-<mtime ms>-<sha256 hex>`.
/// Analysis cache keys use the whole string. Relinking a renamed file uses
/// only the content part (size and hash), because a copy can change the
/// modification time without changing the file.
public struct Fingerprint: Hashable, Sendable, CustomStringConvertible {
    /// Bytes read from each end of the file.
    public static let sampleLength = 1 << 20

    public var size: Int64
    /// Modification time in whole milliseconds since 1970.
    public var modified: Int64
    /// Hex SHA-256 of the first and last `sampleLength` bytes.
    public var hash: String

    public init(size: Int64, modified: Int64, hash: String) {
        self.size = size
        self.modified = modified
        self.hash = hash
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3, let size = Int64(parts[0]), let modified = Int64(parts[1]), !parts[2].isEmpty else { return nil }
        self.init(size: size, modified: modified, hash: parts[2])
    }

    public var description: String { "\(size)-\(modified)-\(hash)" }

    /// Size and hash, without the modification time.
    public var contentID: String { "\(size)-\(hash)" }

    /// Reads the file and computes its fingerprint.
    public static func compute(for url: URL) throws -> Fingerprint {
        let stat = try FileStat(url)
        return Fingerprint(size: stat.size, modified: stat.modified, hash: try contentHash(of: url, size: stat.size))
    }

    /// True when the file's size and modification time still match, so the
    /// hash doesn't need recomputing.
    public func matchesStat(of url: URL) -> Bool {
        guard let stat = try? FileStat(url) else { return false }
        return stat.size == size && stat.modified == modified
    }

    static func contentHash(of url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let sample = Int64(sampleLength)
        if size <= 2 * sample {
            // Small files: the ends overlap, so hash the whole thing.
            if let data = try handle.readToEnd() { hasher.update(data: data) }
        } else {
            if let head = try handle.read(upToCount: sampleLength) { hasher.update(data: head) }
            try handle.seek(toOffset: UInt64(size - sample))
            if let tail = try handle.read(upToCount: sampleLength) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Size and modification time from one `stat`.
struct FileStat: Equatable, Sendable {
    var size: Int64
    /// Milliseconds since 1970.
    var modified: Int64

    init(size: Int64, modified: Int64) {
        self.size = size
        self.modified = modified
    }

    init(_ url: URL) throws {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        size = Int64(info.st_size)
        modified = Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
    }
}
