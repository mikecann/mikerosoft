import Foundation
import TandemCore
import TandemMedia

/// One open project: the file, its coordinator, its analysis, autosave and
/// the lock that says who owns it.
///
/// Ownership rule: while the app has a project open it owns the file and
/// agents go through the app's API. When the app is closed the CLI opens the
/// file itself. Two writers never share a file, so there's nothing to merge.
///
/// The lock is `.tandem/<name>.lock`, held with `flock` for as long as the
/// session is open. The kernel drops the lock if the process dies, so a
/// crash never leaves a project locked, and two processes racing to open
/// the same project can't both win. The file's contents (pid, owner, API
/// port and token) are for other processes to read.
public final class ProjectSession: @unchecked Sendable {
    public enum Owner: String, Codable, Sendable { case app, cli }

    public struct Lock: Codable, Equatable, Sendable {
        public var pid: Int32
        public var owner: Owner
        public var started: Date
        /// Local API port when the owner serves one.
        public var port: Int?
        public var token: String?
    }

    public let fileURL: URL
    public let folder: ProjectFolder
    public let coordinator: ProjectCoordinator
    public let analysis: MediaAnalysis
    public let owner: Owner
    public private(set) var savedRevision: Int
    /// Set when the journal had edits the last save didn't include.
    public let recoveredEdits: Bool

    private let journal: ProjectJournal
    private let lockHandle: LockHandle
    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.session")
    private var autosaveWork: DispatchWorkItem?
    private var observerToken: UUID?
    private var closed = false
    public var autosaveDelay: TimeInterval = 1

    private init(fileURL: URL, project: Project, revision: Int, owner: Owner, recovered: Bool, journal: ProjectJournal, lock: LockHandle) {
        self.fileURL = fileURL
        self.folder = ProjectFolder(projectFile: fileURL)
        self.journal = journal
        self.lockHandle = lock
        self.coordinator = ProjectCoordinator(project: project, revision: revision, journal: journal)
        self.analysis = MediaAnalysis(folder: folder)
        self.owner = owner
        self.savedRevision = recovered ? -1 : revision
        self.recoveredEdits = recovered
    }

    deinit {
        // A session dropped without `close()` still gives the lock back.
        lockHandle.release()
    }

    /// Opens a project, replaying any edits the journal holds from a crash,
    /// and takes the lock.
    public static func open(_ url: URL, owner: Owner) throws -> ProjectSession {
        let url = url.standardizedFileURL
        let lock = try claimLock(for: url, owner: owner)
        do {
            let (project, revision) = try ProjectFile.load(from: url)
            let journal = ProjectJournal.forProject(at: url)
            var recovered = false
            var start = (project, revision)
            if let replayed = journal.recover(project: project, revision: revision) {
                start = replayed
                recovered = true
            }
            let session = ProjectSession(fileURL: url, project: start.0, revision: start.1, owner: owner, recovered: recovered, journal: journal, lock: lock)
            session.startAutosave()
            if recovered { try session.save() }
            return session
        } catch {
            lock.release()
            throw error
        }
    }

    /// Creates a new project with Mike's usual tracks in `url`'s folder.
    public static func create(at url: URL, name: String? = nil, owner: Owner) throws -> ProjectSession {
        let url = url.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw EditError.invalid("\(url.path) already exists")
        }
        let project = Project.standard(name: name ?? url.deletingPathExtension().lastPathComponent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectFile.save(project, revision: 0, to: url)
        return try open(url, owner: owner)
    }

    public var isDirty: Bool { coordinator.revision != savedRevision }

    /// Writes the project atomically and clears the journal.
    public func save() throws {
        try queue.sync {
            let (project, revision) = coordinator.snapshot()
            guard revision != savedRevision else { return }
            try ProjectFile.save(project, revision: revision, to: fileURL)
            journal.truncate()
            savedRevision = revision
        }
    }

    /// Saves pending edits, stops autosave and releases the lock. Safe to
    /// call more than once.
    public func close() {
        let first: Bool = queue.sync {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        if let token = observerToken { coordinator.removeObserver(token) }
        queue.sync { autosaveWork?.cancel() }
        try? save()
        analysis.cancelAll()
        lockHandle.release()
    }

    /// Adds files that appeared in the folder since the last scan, as one
    /// edit by "system". Returns the new media IDs.
    @discardableResult
    public func refreshMedia() async throws -> [String] {
        let project = coordinator.project
        let scanned = try await MediaScanner.scan(folder, known: project.media)
        let known = Set(project.media.map(\.id))
        var commands: [EditCommand] = []
        for item in scanned {
            if known.contains(item.id) {
                if let old = project.media(item.id), old != item,
                   let patch = try? JSONValue.from(item) {
                    commands.append(.updateMedia(mediaID: item.id, patch: patch))
                }
            } else {
                commands.append(.addMedia(item: item))
            }
        }
        guard !commands.isEmpty else { return [] }
        try coordinator.apply(EditBatch(label: "Found new media", author: "system", commands: commands))
        let used = Set(coordinator.project.allTracks.flatMap(\.clips).compactMap(\.mediaID))
        analysis.requestDefaults(for: coordinator.project.media, usedOnTimeline: used)
        return scanned.map(\.id).filter { !known.contains($0) }
    }

    /// Records the API endpoint in the lock so the CLI can find the app.
    public func advertise(port: Int, token: String) throws {
        var lock = lockHandle.lock
        lock.port = port
        lock.token = token
        try lockHandle.write(lock)
    }

    /// Takes the API endpoint back out of the lock, when the server stops
    /// but the project stays open.
    public func stopAdvertising() throws {
        var lock = lockHandle.lock
        lock.port = nil
        lock.token = nil
        try lockHandle.write(lock)
    }

    // MARK: - Autosave

    private func startAutosave() {
        observerToken = coordinator.observe { [weak self] _ in
            self?.scheduleAutosave()
        }
    }

    private func scheduleAutosave() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.autosaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in try? self?.save() }
            self.autosaveWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.autosaveDelay, execute: work)
        }
    }

    // MARK: - Lock

    public static func lockURL(for projectURL: URL) -> URL {
        ProjectFolder(projectFile: projectURL).supportFolder
            .appendingPathComponent(projectURL.deletingPathExtension().lastPathComponent + ".lock")
    }

    public static func readLock(for projectURL: URL) -> Lock? {
        guard let data = try? Data(contentsOf: lockURL(for: projectURL)) else { return nil }
        return try? LockHandle.decoder.decode(Lock.self, from: data)
    }

    /// The live owner of a project, if another process has it open.
    public static func liveLock(for projectURL: URL) -> Lock? {
        let url = lockURL(for: projectURL.standardizedFileURL)
        guard LockHandle.isHeld(url), let lock = readLock(for: projectURL), lock.pid != getpid() else { return nil }
        return lock
    }

    private static func claimLock(for projectURL: URL, owner: Owner) throws -> LockHandle {
        let url = lockURL(for: projectURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = Lock(pid: getpid(), owner: owner, started: Date())
        // A lock whose file is swapped out between open and flock is retried.
        for _ in 0..<5 {
            switch try LockHandle.acquire(url, lock: lock) {
            case .acquired(let handle):
                return handle
            case .held:
                let holder = readLock(for: projectURL)
                if holder?.pid == getpid() {
                    throw EditError.locked("\(projectURL.lastPathComponent) is already open in this process.")
                }
                let who = holder.map { " (\($0.owner.rawValue), pid \($0.pid))" } ?? ""
                throw EditError.locked("\(projectURL.lastPathComponent) is open in Tandem\(who). Use its API instead.")
            case .replaced:
                continue
            }
        }
        throw EditError.locked("Couldn't take the lock on \(projectURL.lastPathComponent); another process keeps replacing it.")
    }
}

/// An open lock file with `flock` held on it.
final class LockHandle: @unchecked Sendable {
    enum Outcome {
        case acquired(LockHandle)
        /// Another open file description holds the lock.
        case held
        /// The file was removed or replaced while it was being locked.
        case replaced
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    let url: URL
    private let fd: Int32
    private let mutex = NSLock()
    private var released = false
    private(set) var lock: ProjectSession.Lock

    private init(url: URL, fd: Int32, lock: ProjectSession.Lock) {
        self.url = url
        self.fd = fd
        self.lock = lock
    }

    static func acquire(_ url: URL, lock: ProjectSession.Lock) throws -> Outcome {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw EditError.locked("Couldn't open the lock file \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK { return .held }
            throw EditError.locked("Couldn't lock \(url.path): \(String(cString: strerror(error)))")
        }
        // Whoever held it last may have unlinked the file after we opened it.
        var opened = stat()
        var current = stat()
        guard fstat(fd, &opened) == 0, stat(url.path, &current) == 0,
              opened.st_ino == current.st_ino, opened.st_dev == current.st_dev else {
            close(fd)
            return .replaced
        }
        let handle = LockHandle(url: url, fd: fd, lock: lock)
        try handle.write(lock)
        return .acquired(handle)
    }

    /// True when some process holds the lock on `url`.
    static func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Rewrites the lock's contents in place, keeping the held file.
    func write(_ lock: ProjectSession.Lock) throws {
        let data = try Self.encoder.encode(lock)
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        guard ftruncate(fd, 0) == 0 else {
            throw EditError.locked("Couldn't write the lock file: \(String(cString: strerror(errno)))")
        }
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == data.count else {
            throw EditError.locked("Couldn't write the lock file: \(String(cString: strerror(errno)))")
        }
        self.lock = lock
    }

    /// Removes the lock file (if it's still ours) and drops the lock.
    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        released = true
        var opened = stat()
        var current = stat()
        if fstat(fd, &opened) == 0, stat(url.path, &current) == 0,
           opened.st_ino == current.st_ino, opened.st_dev == current.st_dev {
            unlink(url.path)
        }
        close(fd)
    }
}
