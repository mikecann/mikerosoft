import CryptoKit
import Darwin
import Foundation

/// Lets a long archive or relink be stopped from another thread (the app's
/// Cancel button, a task cancelled by its caller). Work checks it between
/// files and between chunks of a file.
public final class ArchiveControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Throws `CancellationError` once cancelled.
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Copies and checks files for archiving.
///
/// A copy is `copyfile` with `COPYFILE_CLONE`: an APFS clone when the source
/// and destination share a volume (instant, and no extra space until one of
/// them changes), otherwise a full copy of the data, metadata and dates.
/// Modification dates must survive, because a media file's fingerprint
/// includes it and the analysis cache (transcripts) is keyed by the
/// fingerprint.
enum FileCopier {
    /// How a file got to its destination.
    enum Method: String, Sendable {
        case cloned, copied
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Copies `source` to `destination`, which must not exist yet.
    /// `progress` gets the bytes copied so far (never called for a clone).
    /// `clone: false` always copies the data (tests use it to take the
    /// network-share path on one volume).
    static func copy(_ source: URL, to destination: URL, clone: Bool = true, control: ArchiveControl?, progress: (Int64) -> Void) throws -> Method {
        let flags = clone ? COPYFILE_CLONE : COPYFILE_ALL | COPYFILE_EXCL
        do {
            return try attempt(source, destination, flags: flags, control: control, progress: progress) ? .cloned : .copied
        } catch let failure as Failure {
            // Both of those copy ACLs and extended attributes too, which
            // some file systems refuse; the last try is data and dates.
            do {
                _ = try attempt(source, destination, flags: COPYFILE_DATA | COPYFILE_STAT | COPYFILE_EXCL, control: control, progress: progress)
                return .copied
            } catch is Failure {
                throw failure
            }
        }
    }

    /// One `copyfile` call. Returns true when the result is a clone.
    private static func attempt(_ source: URL, _ destination: URL, flags: Int32, control: ArchiveControl?, progress: (Int64) -> Void) throws -> Bool {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        return try withoutActuallyEscaping(progress) { progress in
            let box = CopyProgressBox(control: control, progress: progress)
            let callback: copyfile_callback_t = { what, stage, state, _, _, context in
                guard let context else { return COPYFILE_CONTINUE }
                let box = Unmanaged<CopyProgressBox>.fromOpaque(context).takeUnretainedValue()
                if box.control?.isCancelled == true { return COPYFILE_QUIT }
                if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                    var copied: off_t = 0
                    copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                    box.progress(Int64(copied))
                }
                return COPYFILE_CONTINUE
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(box).toOpaque())
            let result = copyfile(source.path, destination.path, state, copyfile_flags_t(flags))
            let error = errno
            guard result == 0 else {
                try? FileManager.default.removeItem(at: destination)
                if error == ECANCELED || control?.isCancelled == true { throw CancellationError() }
                throw Failure(message: "Couldn't copy \(source.path) to \(destination.path): \(String(cString: strerror(error))).")
            }
            var cloned: Int32 = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &cloned)
            return cloned != 0
        }
    }

    // MARK: - Checks

    /// SHA-256 of a whole file, read in large chunks without filling the
    /// page cache (so hashing a 10 GB take doesn't push everything else
    /// out, and a copy on a network share is read back from the share).
    static func sha256(of url: URL, control: ArchiveControl?, progress: (Int64) -> Void = { _ in }) throws -> String {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw Failure(message: "Couldn't read \(url.path): \(String(cString: strerror(errno))).")
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16_384)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try control?.check()
            let count = read(fd, buffer, chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure(message: "Couldn't read \(url.path): \(String(cString: strerror(errno))).")
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            total += Int64(count)
            progress(total)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Size and modification date of a regular file (following links), or
    /// nil when there's no regular file there.
    static func fileInfo(_ url: URL) -> (size: Int64, modified: Date)? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return (Int64(info.st_size), modified)
    }

    /// True when anything is at `url`, a dangling link included.
    static func anythingAt(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// True for a regular file that isn't a link.
    static func isPlainFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Modification time in whole milliseconds, the precision fingerprints
    /// use.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// Gives `url` the modification date `date` when a copy lost it (some
    /// network file systems round it).
    static func keepDate(_ date: Date, on url: URL) {
        guard let now = fileInfo(url)?.modified, milliseconds(now) != milliseconds(date) else { return }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Renames `from` to `to` unless something is already at `to`. Returns
    /// false (leaving both alone) when it is.
    static func moveIntoPlace(_ from: URL, _ to: URL) throws -> Bool {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let error = errno
        if error == EEXIST { return false }
        throw Failure(message: "Couldn't move \(from.lastPathComponent) into place at \(to.path): \(String(cString: strerror(error))).")
    }

    // MARK: - Names

    /// Where a file waits while it's copied and checked: hidden, beside its
    /// destination, so a copy cut short is never mistaken for the file and
    /// the folder watcher doesn't pick it up.
    static let temporarySuffix = ".tandem-copy"

    static func temporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent)\(temporarySuffix)")
    }

    static func isTemporary(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(temporarySuffix)
    }

    /// The `n`th name for a file that has to go beside another of the same
    /// name: `music/bed.m4a` becomes `music/bed 2.m4a`, then `bed 3.m4a`.
    static func alongside(_ path: String, _ n: Int) -> String {
        guard n > 1 else { return path }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let numbered = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
        return folder.isEmpty ? numbered : "\(folder)/\(numbered)"
    }
}

/// What `copyfile`'s C callback reaches through its context pointer.
private final class CopyProgressBox {
    let control: ArchiveControl?
    let progress: (Int64) -> Void

    init(control: ArchiveControl?, progress: @escaping (Int64) -> Void) {
        self.control = control
        self.progress = progress
    }
}
