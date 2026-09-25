import Foundation
import TandemCore
import TandemMedia

/// One open project: the file, its coordinator, its analysis, autosave and
/// the lock that says who owns it.
///
/// Ownership rule: while the app has a project open it owns the file and
/// agents go through the app's API. When the app is closed the CLI opens the
/// file itself. Two writers never share a file, so there's nothing to merge.
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
    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.session")
    private var autosaveWork: DispatchWorkItem?
    private var observerToken: UUID?
    public var autosaveDelay: TimeInterval = 1

    private init(fileURL: URL, project: Project, revision: Int, owner: Owner, recovered: Bool, journal: ProjectJournal) {
        self.fileURL = fileURL
        self.folder = ProjectFolder(projectFile: fileURL)
        self.journal = journal
        self.coordinator = ProjectCoordinator(project: project, revision: revision, journal: journal)
        self.analysis = MediaAnalysis(folder: folder)
        self.owner = owner
        self.savedRevision = recovered ? -1 : revision
        self.recoveredEdits = recovered
    }

    /// Opens a project, replaying any edits the journal holds from a crash,
    /// and takes the lock.
    public static func open(_ url: URL, owner: Owner) throws -> ProjectSession {
        let url = url.standardizedFileURL
        try claimLock(for: url, owner: owner)
        let (project, revision) = try ProjectFile.load(from: url)
        let journal = ProjectJournal.forProject(at: url)
        var recovered = false
        var start = (project, revision)
        if let replayed = journal.recover(project: project, revision: revision) {
            start = replayed
            recovered = true
        }
        let session = ProjectSession(fileURL: url, project: start.0, revision: start.1, owner: owner, recovered: recovered, journal: journal)
        session.startAutosave()
        if recovered { try session.save() }
        return session
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

    /// Saves pending edits, stops autosave and releases the lock.
    public func close() {
        if let token = observerToken { coordinator.removeObserver(token) }
        autosaveWork?.cancel()
        try? save()
        analysis.cancelAll()
        Self.releaseLock(for: fileURL)
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
        let result = try coordinator.apply(EditBatch(label: "Found new media", author: "system", commands: commands))
        _ = result
        let used = Set(coordinator.project.allTracks.flatMap(\.clips).compactMap(\.mediaID))
        analysis.requestDefaults(for: coordinator.project.media, usedOnTimeline: used)
        return scanned.map(\.id).filter { !known.contains($0) }
    }

    /// Records the API endpoint in the lock so the CLI can find the app.
    public func advertise(port: Int, token: String) throws {
        var lock = Self.readLock(for: fileURL) ?? Lock(pid: getpid(), owner: owner, started: Date())
        lock.port = port
        lock.token = token
        try Self.writeLock(lock, for: fileURL)
    }

    // MARK: - Autosave

    private func startAutosave() {
        observerToken = coordinator.observe { [weak self] _ in
            self?.scheduleAutosave()
        }
    }

    private func scheduleAutosave() {
        queue.async { [weak self] in
            guard let self else { return }
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: lockURL(for: projectURL)) else { return nil }
        return try? decoder.decode(Lock.self, from: data)
    }

    /// The live owner of a project, if another process has it open.
    public static func liveLock(for projectURL: URL) -> Lock? {
        guard let lock = readLock(for: projectURL), lock.pid != getpid(), kill(lock.pid, 0) == 0 else { return nil }
        return lock
    }

    private static func writeLock(_ lock: Lock, for projectURL: URL) throws {
        let url = lockURL(for: projectURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(lock).write(to: url, options: .atomic)
    }

    private static func claimLock(for projectURL: URL, owner: Owner) throws {
        if let live = liveLock(for: projectURL) {
            throw EditError.locked("\(projectURL.lastPathComponent) is open in Tandem (\(live.owner.rawValue), pid \(live.pid)). Use its API instead.")
        }
        try writeLock(Lock(pid: getpid(), owner: owner, started: Date()), for: projectURL)
    }

    private static func releaseLock(for projectURL: URL) {
        if let lock = readLock(for: projectURL), lock.pid == getpid() {
            try? FileManager.default.removeItem(at: lockURL(for: projectURL))
        }
    }
}
