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

    public static func save(_ project: Project, revision: Int, to url: URL, keepBackups: Int = 20) throws {
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

    /// Clears the journal and undo history an earlier file of this name
    /// left behind, for a file that takes its place (a new project, a
    /// version saved over another, a fresh import). Both describe the old
    /// file's timeline: replayed or undone onto the new one, they'd bring
    /// the old one back.
    public static func forgetHistory(of projectURL: URL) {
        ProjectJournal.forProject(at: projectURL).truncate()
        try? FileManager.default.removeItem(at: undoHistoryURL(for: projectURL))
    }

    private static func backup(_ url: URL, keep: Int) throws {
        let fm = FileManager.default
        let folder = supportFolder(for: url).appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.backupStamp.string(from: Date())
        let name = url.deletingPathExtension().lastPathComponent
        let target = folder.appendingPathComponent("\(name) \(stamp).\(fileExtension)")
        if !fm.fileExists(atPath: target.path) {
            try fm.copyItem(at: url, to: target)
        }
        let existing = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
            .filter { isBackup($0.lastPathComponent, of: name) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if existing.count > keep {
            for old in existing.prefix(existing.count - keep) {
                try? fm.removeItem(at: old)
            }
        }
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

    /// Upgrades older schema versions. Version 1 is the first.
    public static func migrate(_ project: Project) throws -> Project {
        guard project.schemaVersion <= Project.currentSchemaVersion else {
            throw EditError.invalid("This project was saved by a newer Tandem (schema \(project.schemaVersion)).")
        }
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
    }

    public let url: URL
    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.journal")

    public init(url: URL) {
        self.url = url
    }

    public static func forProject(at projectURL: URL) -> ProjectJournal {
        let folder = ProjectFile.supportFolder(for: projectURL)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ProjectJournal(url: ProjectFile.journalURL(for: projectURL))
    }

    public func append(batch: EditBatch, revision: Int, seed: UInt64) {
        write(Entry(revision: revision, date: Date(), batch: batch, seed: seed, snapshot: nil, reason: nil))
    }

    public func appendSnapshot(project: Project, revision: Int, reason: String) {
        write(Entry(revision: revision, date: Date(), batch: nil, seed: nil, snapshot: project, reason: reason))
    }

    /// Entries newer than `revision`, oldest first.
    public func entries(after revision: Int) -> [Entry] {
        queue.sync {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n").compactMap { line in
                try? decoder.decode(Entry.self, from: Data(line.utf8))
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
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    /// Replays journal entries newer than `revision` on top of `project`.
    /// Returns the recovered project and revision, or nil if there was
    /// nothing to recover.
    public func recover(project: Project, revision: Int) -> (project: Project, revision: Int)? {
        let pending = entries(after: revision)
        guard !pending.isEmpty else { return nil }
        var current = project
        var currentRevision = revision
        for entry in pending {
            if let snapshot = entry.snapshot {
                current = snapshot
            } else if let batch = entry.batch {
                var context = EditContext(seed: entry.seed ?? 0)
                var working = current
                do {
                    for command in batch.commands {
                        try Editing.apply(command, to: &working, context: &context)
                    }
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

extension ISO8601DateFormatter {
    static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
