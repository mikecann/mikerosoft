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

    /// Where the project file is now. If Mike renames or moves the video
    /// folder while it's open, saves follow it there. (`folder`, which
    /// media paths resolve against, stays where it was opened until the
    /// project is opened again.)
    public var fileURL: URL { projectFolder.url.appendingPathComponent(fileName) }
    public let folder: ProjectFolder
    private let projectFolder: FolderAnchor
    private let fileName: String
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
    private var watcher: FolderWatcher?
    private var analysisObserver: UUID?
    private var analysisWork: DispatchWorkItem?
    private var _saveProblem: String?
    public var autosaveDelay: TimeInterval = 1
    /// How soon an autosave that failed tries again, so fixing the cause (a
    /// full disk, a folder back where it was) is enough.
    public var autosaveRetryDelay: TimeInterval = 5

    private init(fileURL: URL, project: Project, revision: Int, owner: Owner, recovered: Bool, journal: ProjectJournal, lock: LockHandle) {
        self.projectFolder = FolderAnchor(fileURL.deletingLastPathComponent())
        self.fileName = fileURL.lastPathComponent
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
            let (project, revision) = try load(url)
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

    /// Reads the project file. When it isn't a project Tandem can read (cut
    /// short, or broken by a hand edit), says where the previous saves are.
    static func load(_ url: URL) throws -> (project: Project, revision: Int) {
        do {
            return try ProjectFile.load(from: url)
        } catch let error as DecodingError {
            let reason = DecodingErrorText.describe(error)
            var message = "\(url.lastPathComponent) couldn't be read: \(reason)\(reason.hasSuffix(".") ? "" : ".")"
            if let newest = ProjectFile.backups(of: url).last {
                message += " The previous saves are in .tandem/backups/ next to it; the newest is \"\(newest.lastPathComponent)\". Copy one over \(url.lastPathComponent) to go back to it."
            }
            throw ServiceError(.invalid, message)
        }
    }

    /// Creates a new project with Mike's usual tracks in `url`'s folder.
    public static func create(at url: URL, name: String? = nil, settings: ProjectSettings? = nil, owner: Owner) throws -> ProjectSession {
        let url = url.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ServiceError(.invalid, "\(url.path) already exists. Open it instead, or pick another name.")
        }
        var project = Project.standard(name: name ?? url.deletingPathExtension().lastPathComponent)
        if let settings { project.settings = settings }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A deleted project of this name may have left a journal or undo
        // history; opening would replay it over the new project.
        ProjectFile.forgetHistory(of: url)
        try ProjectFile.save(project, revision: 0, to: url)
        return try open(url, owner: owner)
    }

    public var isDirty: Bool { coordinator.revision != savedRevision }

    /// Why the last save failed, until a save works. Autosave failures are
    /// otherwise silent, so the app shows this.
    public var saveProblem: String? { queue.sync { _saveProblem } }

    /// Writes the project atomically and clears the journal up to what
    /// was written. Edits keep committing while the file is written, and
    /// their journal entries stay until the save that includes them.
    public func save() throws {
        try queue.sync {
            let (project, revision) = coordinator.snapshot()
            guard revision != savedRevision else {
                _saveProblem = nil
                return
            }
            do {
                try ProjectFile.save(project, revision: revision, to: fileURL)
            } catch {
                _saveProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw error
            }
            journal.truncate(through: revision)
            savedRevision = revision
            _saveProblem = nil
        }
    }

    /// Saves pending edits, stops autosave and releases the lock. Safe to
    /// call more than once. Returns why the last save failed, if it did;
    /// the edits it missed stay in the journal for the next open.
    @discardableResult
    public func close() -> Error? {
        let first: Bool = queue.sync {
            defer { closed = true }
            return !closed
        }
        guard first else { return nil }
        stopWatching()
        if let token = observerToken { coordinator.removeObserver(token) }
        queue.sync { autosaveWork?.cancel() }
        var failure: Error?
        do {
            try save()
        } catch {
            failure = error
        }
        analysis.cancelAll()
        lockHandle.release()
        return failure
    }

    /// For long-lived sessions (the app and `tandem serve`, not one-shot CLI
    /// commands): starts the usual background analysis for the project's
    /// media, timeline media first, and watches the folder so files that
    /// land in it (a new record-it take, a downloaded sound) join the
    /// project on their own.
    public func startWatching() {
        let started: Bool = queue.sync {
            guard watcher == nil, !closed else { return false }
            let watcher = FolderWatcher(folder: folder) { [weak self] changes in
                guard let self, !changes.isEmpty else { return }
                Task { _ = try? await self.refreshMedia() }
            }
            do {
                try watcher.start()
            } catch {
                return false
            }
            self.watcher = watcher
            return true
        }
        guard started else { return }
        analysis.requestNeeded(for: coordinator.project)
        // Placing a take or turning on a cutout queues its analysis. A burst
        // of edits (dragging, tightening) settles first.
        let token = coordinator.observe { [weak self] _ in self?.scheduleAnalysisCheck() }
        queue.sync { analysisObserver = token }
        Task { [weak self] in _ = try? await self?.refreshMedia() }
    }

    private func scheduleAnalysisCheck() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.analysisWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.analysis.requestNeeded(for: self.coordinator.project)
            }
            self.analysisWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    public func stopWatching() {
        let (current, token): (FolderWatcher?, UUID?) = queue.sync {
            defer {
                watcher = nil
                analysisObserver = nil
                analysisWork?.cancel()
                analysisWork = nil
            }
            return (watcher, analysisObserver)
        }
        current?.stop()
        if let token { coordinator.removeObserver(token) }
    }

    public var isWatching: Bool { queue.sync { watcher != nil } }

    /// Adds files that appeared in the folder since the last scan, as one
    /// edit by "system". Returns the new media IDs.
    ///
    /// The project can change while the folder is scanned: another scan
    /// can add the same new files first (opening a project in the app
    /// starts two), or Mike can edit. So the edit is worked out against the
    /// project as it is when it's applied, and worked out again if it
    /// changes in between.
    @discardableResult
    public func refreshMedia() async throws -> [String] {
        try await refreshMediaReport().added
    }

    /// `refreshMedia`, also saying which of the files it added are camera
    /// takes and why, for `tandem new` to tell Mike.
    public func refreshMediaReport() async throws -> MediaRefresh {
        let project = coordinator.project
        let report = try await MediaScanner.scanReport(folder, known: project.media)
        var attempt = 0
        while true {
            attempt += 1
            let (current, revision) = coordinator.snapshot()
            let (commands, added) = Self.refreshCommands(report.items, scannedFrom: project, into: current, folder: folder)
            guard !commands.isEmpty else { return MediaRefresh(added: [], cameraTakes: []) }
            do {
                try coordinator.apply(EditBatch(label: "Found new media", author: "system", commands: commands, expectedRevision: revision))
            } catch EditError.staleRevision where attempt < 20 {
                continue
            }
            analysis.requestNeeded(for: coordinator.project)
            let ids = Set(added)
            return MediaRefresh(added: added, cameraTakes: report.cameraTakes.filter { ids.contains($0.mediaID) })
        }
    }

    /// The edit that brings a scan's results into `current`, and the IDs of
    /// the media it adds. `scannedFrom` is the project the scan started
    /// from.
    static func refreshCommands(_ scanned: [MediaItem], scannedFrom project: Project, into current: Project, folder: ProjectFolder) -> (commands: [EditCommand], added: [String]) {
        let known = Set(project.media.map(\.id))
        let paths = Set(current.media.map { folder.path(for: folder.url(for: $0)) })
        var commands: [EditCommand] = []
        var added: [String] = []
        for item in scanned {
            if known.contains(item.id) {
                // Only what the scan changed, so an edit made while it ran
                // (a new look, a role) stays, and never the ID, which
                // updateMedia refuses. Media removed meanwhile stays removed.
                if current.media(item.id) != nil, let old = project.media(item.id), old != item,
                   let before = try? JSONValue.from(old), let after = try? JSONValue.from(item),
                   let patch = JSONValue.mergePatch(from: before, to: after) {
                    commands.append(.updateMedia(mediaID: item.id, patch: patch))
                }
            } else if !paths.contains(folder.path(for: folder.url(for: item))) {
                commands.append(.addMedia(item: item))
                added.append(item.id)
            }
        }
        return (commands, added)
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

    private func scheduleAutosave(after delay: TimeInterval? = nil) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.autosaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                do {
                    try self.save()
                } catch {
                    // Recorded in saveProblem; try again until it works.
                    self.scheduleAutosave(after: self.autosaveRetryDelay)
                }
            }
            self.autosaveWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (delay ?? self.autosaveDelay), execute: work)
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

    /// Removes the lock file (if it's still ours) and drops the lock. The
    /// file is found where it is now, in case the folder was renamed.
    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        released = true
        let path = FolderAnchor.path(of: fd) ?? url.path
        var opened = stat()
        var current = stat()
        if fstat(fd, &opened) == 0, stat(path, &current) == 0,
           opened.st_ino == current.st_ino, opened.st_dev == current.st_dev {
            unlink(path)
        }
        close(fd)
    }
}

/// What a media refresh added.
public struct MediaRefresh: Sendable {
    /// IDs of the media it added.
    public var added: [String]
    /// The camera takes among them, and why each is one.
    public var cameraTakes: [CameraTakeNote]

    public init(added: [String], cameraTakes: [CameraTakeNote]) {
        self.added = added
        self.cameraTakes = cameraTakes
    }
}
