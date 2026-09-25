import CoreServices
import Foundation

/// Watches a project folder (recursively, with FSEvents) and reports media
/// files that were added, changed or removed, as paths relative to the
/// folder. Skipped folders (`.tandem`, `exports`, hidden ones...) and
/// non-media files are ignored.
///
/// Events are debounced, and a file is only reported once it has stopped
/// changing for `settleTime`, so a take that record-it is still writing is
/// reported once, when it's done. Hand the changes to
/// `MediaScanner.scanReport` to update the project.
public final class FolderWatcher: @unchecked Sendable {
    public struct Changes: Equatable, Sendable {
        public var added: [String] = []
        public var changed: [String] = []
        public var removed: [String] = []

        public init(added: [String] = [], changed: [String] = [], removed: [String] = []) {
            self.added = added
            self.changed = changed
            self.removed = removed
        }

        public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }
    }

    public let folder: ProjectFolder
    public let debounce: TimeInterval
    public let settleTime: TimeInterval

    private let handler: @Sendable (Changes) -> Void
    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.media.watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    /// What each media file looked like when last reported (or at start).
    private var known: [String: FileStat] = [:]
    private var pending: Set<String> = []
    private var rescan = false
    private var check: DispatchWorkItem?
    private let roots: [String]
    /// Full rescans so far, for tests.
    private(set) var rescans = 0
    private let onQueue = DispatchSpecificKey<Bool>()
    /// What the FSEvents callback holds: a weak route back to the watcher,
    /// so a callback racing with deinit finds nil instead of a dead object.
    private final class Route {
        weak var watcher: FolderWatcher?
        init(_ watcher: FolderWatcher) { self.watcher = watcher }
    }
    private var route: Unmanaged<Route>?

    /// - Parameters:
    ///   - debounce: quiet time after the last event before looking.
    ///   - settleTime: how long a file must be unchanged before it's reported.
    ///   - handler: called on a private queue with each batch of changes.
    public init(folder: ProjectFolder, debounce: TimeInterval = 1, settleTime: TimeInterval = 2, handler: @escaping @Sendable (Changes) -> Void) {
        self.folder = folder
        self.debounce = debounce
        self.settleTime = settleTime
        self.handler = handler
        // FSEvents reports real paths (/private/var/...), the project may use
        // a symlinked one (/var/...). Match both.
        // (resolvingSymlinksInPath strips /private, so ask realpath).
        let plain = folder.root.path
        let real = realpath(plain, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? plain
        roots = Array(Set([plain, real])).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        queue.setSpecific(key: onQueue, value: true)
    }

    deinit { onWatcherQueue { stopStream() } }

    public var isRunning: Bool { onWatcherQueue { stream != nil } }

    /// Runs on the watcher queue, directly when already on it (the handler
    /// may call `stop()`).
    private func onWatcherQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: onQueue) == true { return try body() }
        return try queue.sync(execute: body)
    }

    /// Takes a snapshot of the folder and starts watching. Files already
    /// there aren't reported.
    public func start() throws {
        try onWatcherQueue {
            guard stream == nil else { return }
            known = snapshot()
            let route = Unmanaged.passRetained(Route(self))
            self.route = route
            var context = FSEventStreamContext(version: 0, info: route.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(
                nil, FolderWatcher.callback, &context, [folder.root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
            ) else {
                releaseRoute()
                throw MediaError.failed("Couldn't watch \(folder.root.path)")
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                releaseRoute()
                throw MediaError.failed("Couldn't start watching \(folder.root.path)")
            }
            stream = created
        }
    }

    public func stop() {
        onWatcherQueue { stopStream() }
    }

    private func stopStream() {
        check?.cancel()
        check = nil
        pending = []
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        releaseRoute()
    }

    private func releaseRoute() {
        route?.release()
        route = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, let watcher = Unmanaged<Route>.fromOpaque(info).takeUnretainedValue().watcher else { return }
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        watcher.received(paths: list, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
    }

    /// On the watcher queue.
    private func received(paths: [String], flags: [FSEventStreamEventFlags]) {
        var relevant = false
        for (path, flag) in zip(paths, flags) {
            let flag = Int(flag)
            if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                rescan = true
                relevant = true
                continue
            }
            guard let relative = relativePath(path), !MediaScanner.isSkippedPath(relative) else { continue }
            if flag & kFSEventStreamEventFlagItemIsDir != 0 {
                // A folder moved or vanished: look at everything under it.
                // Tandem's own cache and exports churn constantly and hold no
                // media, so they never trigger that.
                let name = (relative as NSString).lastPathComponent
                if !MediaScanner.isSkippedFolder(name: name),
                   flag & (kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemCreated) != 0 {
                    rescan = true
                    relevant = true
                }
                continue
            }
            guard MediaScanner.mediaKind(forPath: relative) != nil else { continue }
            pending.insert(relative)
            relevant = true
        }
        // Unrelated churn (a log file, node_modules) mustn't keep pushing
        // back reports that are due.
        if relevant { schedule(after: debounce) }
    }

    private func relativePath(_ path: String) -> String? {
        for root in roots where path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        return nil
    }

    private func schedule(after delay: TimeInterval) {
        check?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.look() }
        check = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// On the watcher queue: compares pending paths with what was known.
    private func look() {
        var candidates = pending
        if rescan {
            candidates.formUnion(known.keys)
            candidates.formUnion(snapshot().keys)
            rescan = false
            rescans += 1
        }
        pending = []
        var changes = Changes()
        var unsettled: Set<String> = []
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for path in candidates.sorted() {
            let stat = try? FileStat(folder.url(forPath: path))
            guard let stat else {
                if known.removeValue(forKey: path) != nil { changes.removed.append(path) }
                continue
            }
            if Double(now - stat.modified) / 1000 < settleTime {
                unsettled.insert(path)
                continue
            }
            if let previous = known[path] {
                if previous != stat {
                    changes.changed.append(path)
                    known[path] = stat
                }
            } else {
                changes.added.append(path)
                known[path] = stat
            }
        }
        if !unsettled.isEmpty {
            pending.formUnion(unsettled)
            schedule(after: max(0.2, settleTime / 2))
        }
        if !changes.isEmpty { handler(changes) }
    }

    private func snapshot() -> [String: FileStat] {
        var stats: [String: FileStat] = [:]
        for url in MediaScanner.mediaFiles(in: folder) {
            if let stat = try? FileStat(url) { stats[folder.path(for: url)] = stat }
        }
        return stats
    }
}
