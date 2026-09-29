import Foundation

/// `archive.json` in an archived project folder: where every file the
/// archive brought in came from, with its size, date and SHA-256, and a
/// line for every run, so an archive on Bruce can be traced back and
/// checked years later.
///
///     {
///       "tandemArchive": 1,
///       "project": {"id": "prj_...", "name": "Decision Models", "file": "Decision Models.tandem"},
///       "runs": [{"date": ..., "mode": "archive", "from": "/Users/...", "to": "/Volumes/...", ...}],
///       "files": [{"path": "media/music/score.wav", "original": "/Users/.../music/score.wav",
///                  "kind": "media", "bytes": 192185318, "sha256": "...", "modified": ..., "archived": ...}],
///       "missing": [{"kind": "media", "path": "/Users/.../gone.mov", "usedBy": ["med_x"], "clips": 2}]
///     }
///
/// Consolidating lists the files brought into the folder; archiving to
/// another folder lists every file it copied except the analysis cache.
/// Runs are appended; files are keyed by path, newest first wins.
public struct ArchiveManifest: Codable, Equatable, Sendable {
    public static let fileName = "archive.json"
    public static let currentVersion = 1

    public struct ProjectInfo: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var file: String
    }

    public struct Run: Codable, Equatable, Sendable {
        public var date: Date
        public var mode: ArchiveMode
        /// The folder archived.
        public var from: String
        /// The standalone folder (the same as `from` when consolidating).
        public var to: String
        public var machine: String
        public var user: String
        public var tandem: String
        /// False while a run is copying, so an archive cut short says so.
        public var complete: Bool
        public var collected: Int
        public var copiedFiles: Int
        public var copiedBytes: Int64
        public var reusedFiles: Int
        public var missing: Int
        public var withCache: Bool
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// Relative to the archived folder.
        public var path: String
        /// Where the bytes were.
        public var original: String
        public var kind: ArchivedKind
        public var bytes: Int64
        public var sha256: String?
        /// The file's modification date, which copies keep.
        public var modified: Date?
        public var archived: Date
    }

    public var tandemArchive: Int
    public var project: ProjectInfo
    public var updated: Date
    public var runs: [Run]
    public var files: [Entry]
    public var missing: [MissingFile]

    public init(project: ProjectInfo, updated: Date = Date(), runs: [Run] = [], files: [Entry] = [], missing: [MissingFile] = []) {
        tandemArchive = Self.currentVersion
        self.project = project
        self.updated = updated
        self.runs = runs
        self.files = files
        self.missing = missing
    }

    public static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// The manifest in `folder`, nil when there's none. Throws when an
    /// `archive.json` is there but isn't Tandem's, so it's never written
    /// over.
    public static func load(from folder: URL) throws -> ArchiveManifest? {
        let url = url(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(ArchiveManifest.self, from: Data(contentsOf: url))
        } catch {
            throw ServiceError(.invalid, "\(url.path) isn't a Tandem archive manifest, so the archive won't write over it. Rename it and try again.")
        }
    }

    public func write(to folder: URL) throws {
        var data = try Self.encoder.encode(self)
        data.append(0x0A)
        try data.write(to: Self.url(in: folder), options: .atomic)
    }

    /// Adds or replaces entries by path.
    mutating func record(_ entries: [Entry]) {
        var index = Dictionary(files.enumerated().map { ($0.element.path.lowercased(), $0.offset) }, uniquingKeysWith: { _, last in last })
        for entry in entries {
            if let at = index[entry.path.lowercased()] {
                files[at] = entry
            } else {
                index[entry.path.lowercased()] = files.count
                files.append(entry)
            }
        }
    }

    /// The entry for a path, if there is one.
    func entry(for path: String) -> Entry? {
        files.last { $0.path.caseInsensitiveCompare(path) == .orderedSame }
    }

    /// Dates keep their milliseconds, so a file's recorded modification
    /// date can be checked against the file's own.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(text) isn't a date"))
        }
        return decoder
    }
}
