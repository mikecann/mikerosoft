import Foundation

/// Reading and writing `.tandem` project files.
///
/// The file is pretty-printed JSON with sorted keys so diffs stay readable
/// and agents can inspect it. Writes are atomic (write to a temp file, then
/// rename) and the previous version is kept in `.tandem/backups/`.
public enum ProjectFile {
    public static let fileExtension = "tandem"

    public struct Envelope: Codable, Sendable {
        /// Bumped on every committed edit. Lets the app notice that the CLI
        /// changed the file while it was closed.
        public var revision: Int
        public var project: Project
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func load(from url: URL) throws -> (project: Project, revision: Int) {
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let migrated = try migrate(envelope.project)
        return (migrated, envelope.revision)
    }

    /// Saves atomically, keeping the previous file as a backup. With no
    /// `keepBackups`, backups follow `BackupPolicy`: autosave writes every
    /// second or so, so a backup is only taken when the newest is a minute
    /// old, and older ones thin out over time.
    public static func save(_ project: Project, revision: Int, to url: URL, keepBackups: Int? = nil) throws {
        let data = try encoder().encode(Envelope(revision: revision, project: project))
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try backup(url, keep: keepBackups)
        }
        try data.write(to: url, options: .atomic)
    }

    /// The hidden folder next to the project that holds backups, the journal
    /// and the analysis cache: `<folder>/.tandem/`.
    public static func supportFolder(for projectURL: URL) -> URL {
        projectURL.deletingLastPathComponent().appendingPathComponent(".tandem", isDirectory: true)
    }

    /// `.tandem/<name>.journal.jsonl`: edits since the last save.
    public static func journalURL(for projectURL: URL) -> URL {
        supportFolder(for: projectURL).appendingPathComponent("\(projectURL.deletingPathExtension().lastPathComponent).journal.jsonl")
    }

    /// `.tandem/<name>.undo.json`: undo history for edits made while no app
    /// had the project open.
    public static func undoHistoryURL(for projectURL: URL) -> URL {
        supportFolder(for: projectURL).appendingPathComponent("\(projectURL.deletingPathExtension().lastPathComponent).undo.json")
    }

    /// `.tandem/<name>.review.json`: agent edits Mike hasn't reviewed yet
    /// (see `ReviewLog`).
    public static func reviewURL(for projectURL: URL) -> URL {
        supportFolder(for: projectURL).appendingPathComponent("\(projectURL.deletingPathExtension().lastPathComponent).review.json")
    }

    /// Clears the journal, undo history and review log an earlier file of
    /// this name left behind, for a file that takes its place (a new
    /// project, a version saved over another, a fresh import). They
    /// describe the old file's timeline: replayed or undone onto the new
    /// one, they'd bring the old one back.
    public static func forgetHistory(of projectURL: URL) {
        ProjectJournal.forProject(at: projectURL).truncate()
        try? FileManager.default.removeItem(at: undoHistoryURL(for: projectURL))
        try? FileManager.default.removeItem(at: reviewURL(for: projectURL))
    }

    private static func backup(_ url: URL, keep: Int?, now: Date = Date()) throws {
        let fm = FileManager.default
        let folder = supportFolder(for: url).appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = url.deletingPathExtension().lastPathComponent
        if keep == nil, let newest = backups(of: url).last, let date = backupDate(newest.lastPathComponent, of: name),
           now.timeIntervalSince(date) < BackupPolicy.minimumSpacing {
            return
        }
        let stamp = ISO8601DateFormatter.backupStamp.string(from: now)
        let target = folder.appendingPathComponent("\(name) \(stamp).\(fileExtension)")
        if !fm.fileExists(atPath: target.path) {
            try fm.copyItem(at: url, to: target)
        }
        let existing = backups(of: url)
        let doomed: [URL]
        if let keep {
            doomed = existing.count > keep ? Array(existing.prefix(existing.count - keep)) : []
        } else {
            let dates = existing.map { backupDate($0.lastPathComponent, of: name) ?? now }
            let kept = BackupPolicy.keep(dates, now: now)
            doomed = existing.enumerated().filter { !kept.contains($0.offset) }.map(\.element)
        }
        for old in doomed {
            try? fm.removeItem(at: old)
        }
    }

    /// When a backup was taken, from its file name.
    static func backupDate(_ fileName: String, of name: String) -> Date? {
        guard isBackup(fileName, of: name) else { return nil }
        let stamp = String(fileName.dropFirst(name.count + 1).dropLast(fileExtension.count + 1))
        return ISO8601DateFormatter.backupStamp.date(from: stamp)
    }

    /// The backups of the project at `url` in `.tandem/backups/`, oldest
    /// first.
    public static func backups(of url: URL) -> [URL] {
        let folder = supportFolder(for: url).appendingPathComponent("backups", isDirectory: true)
        let name = url.deletingPathExtension().lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { isBackup($0.lastPathComponent, of: name) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// True for `<name> <stamp>.tandem`, a backup of `<name>.tandem`. A
    /// version saved beside it (`<name> v2.tandem`) has backups that start
    /// the same way, `<name> v2 <stamp>.tandem`, and they aren't this
    /// project's to prune.
    static func isBackup(_ fileName: String, of name: String) -> Bool {
        let prefix = name + " "
        let suffix = "." + fileExtension
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix), fileName.count > prefix.count + suffix.count else { return false }
        let stamp = fileName.dropFirst(prefix.count).dropLast(suffix.count)
        return stamp.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil
    }

    /// Upgrades older schema versions. Version 1 is the first. The result
    /// is marked current, so it's saved as current and never upgraded twice
    /// (an upgrade would drop the explicit values made since).
    public static func migrate(_ project: Project) throws -> Project {
        guard project.schemaVersion <= Project.currentSchemaVersion else {
            throw EditError.invalid("This project was saved by a newer Tandem (schema \(project.schemaVersion)).")
        }
        var project = project
        if project.schemaVersion < 2 { LegacyTextStyles.upgrade(&project) }
        project.schemaVersion = Project.currentSchemaVersion
        return project
    }
}

/// Append-only log of committed edits, for crash recovery.
///
/// Every committed batch is appended as one JSON line. If the app dies before
/// the next save, reopening the project replays the batches written after
/// the saved revision. Undo and redo write a full snapshot instead, since
/// they aren't expressible as forward commands.
public final class ProjectJournal: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var revision: Int
        public var date: Date
        public var batch: EditBatch?
        /// Seed for the IDs the batch created, so a replay makes the same ones.
        public var seed: UInt64?
        public var snapshot: Project?
        public var reason: String?
        /// The project schema the batch was written for. Nil for entries
        /// from before schema 2, whose titles are read the old way.
        public var schemaVersion: Int?
    }

    /// Where the journal is now. It follows its folder if the video folder
    /// is renamed or moved while the project is open.
    public var url: URL { folder.url.appendingPathComponent(fileName) }
    private let folder: FolderAnchor
    private let fileName: String
    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.journal")

    public init(url: URL) {
        folder = FolderAnchor(url.deletingLastPathComponent())
        fileName = url.lastPathComponent
    }

    public static func forProject(at projectURL: URL) -> ProjectJournal {
        let folder = ProjectFile.supportFolder(for: projectURL)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ProjectJournal(url: ProjectFile.journalURL(for: projectURL))
    }

    public func append(batch: EditBatch, revision: Int, seed: UInt64) {
        write(Entry(revision: revision, date: Date(), batch: batch, seed: seed, snapshot: nil, reason: nil, schemaVersion: Project.currentSchemaVersion))
    }

    public func appendSnapshot(project: Project, revision: Int, reason: String) {
        write(Entry(revision: revision, date: Date(), batch: nil, seed: nil, snapshot: project, reason: reason, schemaVersion: Project.currentSchemaVersion))
    }

    /// Entries newer than `revision`, oldest first. Each line is read on
    /// its own, so one cut short by a crash (even mid-character) costs only
    /// itself.
    public func entries(after revision: Int) -> [Entry] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return data.split(separator: 0x0A).compactMap { line in
                try? decoder.decode(Entry.self, from: Data(line))
            }.filter { $0.revision > revision }
        }
    }

    /// Starts a fresh journal, for a file whose journal belongs to
    /// something else (a version saved over an old file of that name).
    public func truncate() {
        queue.sync { try? Data().write(to: url, options: .atomic) }
    }

    /// Drops the entries a save of `revision` includes, after the save.
    /// An edit that committed while the file was being written is newer
    /// than the save, so its entry stays for a crash before the next save.
    public func truncate(through revision: Int) {
        queue.sync {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            struct Header: Decodable { var revision: Int }
            let decoder = JSONDecoder()
            var kept = Data()
            for line in data.split(separator: 0x0A) {
                guard let header = try? decoder.decode(Header.self, from: Data(line)), header.revision > revision else { continue }
                kept.append(contentsOf: line)
                kept.append(0x0A)
            }
            try? kept.write(to: url, options: .atomic)
        }
    }

    private func write(_ entry: Entry) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            // Appends only: opening never replaces what's there (a journal
            // that can't be opened is left alone), and a failed write
            // returns an error where FileHandle's raises an exception, as
            // it does on a full disk.
            let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            // A last line cut short by a crash would swallow this one, so
            // start a new line after it.
            var info = stat()
            if fstat(fd, &info) == 0, info.st_size > 0 {
                var last: UInt8 = 0
                if pread(fd, &last, 1, info.st_size - 1) == 1, last != 0x0A { line.insert(0x0A, at: 0) }
            }
            line.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { return }
                    offset += written
                }
            }
        }
    }

    /// Replays journal entries newer than `revision` on top of `project`.
    /// Returns the recovered project and revision, or nil if there was
    /// nothing to recover. `replayed` hears each entry that took, with the
    /// project before and after it, so an agent's edits that never reached
    /// a save still reach the review log.
    public func recover(
        project: Project, revision: Int,
        replayed: ((_ entry: Entry, _ before: Project, _ after: Project) -> Void)? = nil
    ) -> (project: Project, revision: Int)? {
        let pending = entries(after: revision)
        guard !pending.isEmpty else { return nil }
        var current = project
        var currentRevision = revision
        for entry in pending {
            if let snapshot = entry.snapshot {
                // A snapshot carries its own schema version.
                let before = current
                current = (try? ProjectFile.migrate(snapshot)) ?? snapshot
                replayed?(entry, before, current)
            } else if let batch = entry.batch {
                var context = EditContext(seed: entry.seed ?? 0)
                var working = current
                do {
                    for command in batch.commands {
                        try Editing.apply(command, to: &working, context: &context)
                    }
                    // An older Tandem wrote full styles where it meant
                    // "the preset's". Every edit before this one was that
                    // older Tandem's too, so the whole project reads its way.
                    if (entry.schemaVersion ?? 1) < 2 { LegacyTextStyles.upgrade(&working) }
                    replayed?(entry, current, working)
                    current = working
                } catch {
                    // A batch that no longer applies is skipped rather than
                    // losing everything after it.
                    continue
                }
            }
            currentRevision = entry.revision
        }
        return (current, currentRevision)
    }
}

/// A folder that can be renamed or moved while it's in use (Finder lets
/// Mike rename a video folder with the project open). Holds a descriptor on
/// the folder and asks the system where it is now, so files written into
/// it keep landing in it rather than at the old path.
public final class FolderAnchor: @unchecked Sendable {
    private let original: URL
    private let fd: Int32
    /// Where the system put the folder when it was opened.
    private let openedPath: String?

    public init(_ folder: URL) {
        original = folder
        fd = open(folder.path, O_EVTONLY | O_CLOEXEC)
        openedPath = Self.path(of: fd)
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// The folder as it was given, unless it has moved since, then where
    /// it is now.
    public var url: URL {
        guard let openedPath, let now = Self.path(of: fd), now != openedPath else { return original }
        return URL(fileURLWithPath: now, isDirectory: true)
    }

    /// The path of whatever `fd` is open on, or nil.
    public static func path(of fd: Int32) -> String? {
        guard fd >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }
}

/// Which backups to keep: everything from the last hour, the newest in
/// each ten minutes for the last day, the newest each day for 30 days, and
/// never more than 300. So a morning's editing can be rolled back minute by
/// minute and last week's by the day.
public enum BackupPolicy {
    /// Autosave runs a second after each edit; a backup that often would
    /// push history out of the window within minutes.
    public static let minimumSpacing: TimeInterval = 60
    public static let maximum = 300

    /// Indices of `dates` (oldest first) to keep at `now`.
    public static func keep(_ dates: [Date], now: Date) -> Set<Int> {
        var kept = Set<Int>()
        var buckets = Set<String>()
        // Newest first, so the first backup seen in a bucket is its newest.
        for (index, date) in dates.enumerated().reversed() {
            let age = now.timeIntervalSince(date)
            let bucket: String
            if age < 3600 {
                bucket = "all-\(index)"
            } else if age < 86_400 {
                bucket = "tenMinutes-\(Int(date.timeIntervalSince1970 / 600))"
            } else if age < 30 * 86_400 {
                bucket = "day-\(Int(date.timeIntervalSince1970 / 86_400))"
            } else {
                continue
            }
            if buckets.insert(bucket).inserted { kept.insert(index) }
        }
        if kept.count > maximum {
            for index in kept.sorted().prefix(kept.count - maximum) { kept.remove(index) }
        }
        return kept
    }
}

extension ISO8601DateFormatter {
    static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
