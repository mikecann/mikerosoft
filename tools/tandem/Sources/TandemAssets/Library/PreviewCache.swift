import CryptoKit
import Foundation

/// Previews downloaded for the browser (hover-scrub video, audio snippets,
/// animated stickers), in `~/Library/Caches/Tandem/AssetPreviews`. The
/// folder is capped: when it grows past the limit, the least recently used
/// files go first.
public final class PreviewCache: @unchecked Sendable {
    public let folder: URL
    public let limit: Int64
    private let transport: HTTPTransport
    private let lock = NSLock()

    public init(folder: URL, limit: Int64, transport: HTTPTransport) {
        self.folder = folder
        self.limit = limit
        self.transport = transport
    }

    /// Where a preview URL is (or would be) cached.
    public func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = ProviderFiles.ext(of: url, fallback: "bin")
        return folder.appendingPathComponent("\(digest.prefix(32)).\(ext)")
    }

    /// The cached copy of `url`, downloading it first if needed.
    public func fetch(_ url: URL) async throws -> URL {
        let target = file(for: url)
        if FileManager.default.fileExists(atPath: target.path) {
            touch(target)
            return target
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let response: HTTPURLResponse
        do {
            response = try await transport.download(for: URLRequest(url: url), to: target)
        } catch {
            throw AssetError.network(provider: url.host ?? "preview", message: ProviderHTTP.redact(error.localizedDescription))
        }
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: target)
            throw AssetError.http(provider: url.host ?? "preview", status: response.statusCode, message: "preview download failed")
        }
        touch(target)
        trim()
        return target
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Deletes least recently used previews until the folder fits the limit.
    public func trim() {
        lock.lock()
        defer { lock.unlock() }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int64, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    public var totalSize: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
