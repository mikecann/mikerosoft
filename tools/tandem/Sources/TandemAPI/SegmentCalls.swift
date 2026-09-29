import Foundation
import TandemAssets
import TandemCore
import TandemMedia

// Segments for agents: `tandem segments list | save | insert` and the
// `segments_*` MCP tools. Like the asset library they work on Mike's
// per-user shared library; `save` reads the project and `insert` edits
// it, through the app when it has the project open.

// MARK: - list

public struct SegmentListRequest: AssetCall {
    public static let operation = AssetOperation.segments
    public init() {}

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> SegmentListResult {
        assets.segments()
    }
}

public struct SegmentListResult: Codable, Sendable {
    /// The Segments folder.
    public var folder: String
    /// False when the shared library hasn't been made yet.
    public var exists: Bool
    public var segments: [SegmentSummary]
    /// Folders whose segment.json couldn't be read.
    public var problems: [String]
}

// MARK: - save

public struct SegmentSaveRequest: AssetCall {
    public static let operation = AssetOperation.saveSegment
    public static var needsProject: Bool { true }
    /// What it's called in the library (and its folder's name).
    public var name: String
    /// The clips to save, exactly these (linked partners aren't added).
    public var clipIDs: [String]?
    /// Or every clip that lies wholly between `from` and `to`.
    public var from: Time?
    public var to: Time?
    /// Titles whose words are asked for when it goes in.
    public var fields: [SegmentMaker.Field]?
    /// Replace a segment already called that (the old one goes to the Trash).
    public var replace: Bool?

    public init(name: String, clipIDs: [String]? = nil, from: Time? = nil, to: Time? = nil, fields: [SegmentMaker.Field]? = nil, replace: Bool? = nil) {
        self.name = name
        self.clipIDs = clipIDs
        self.from = from
        self.to = to
        self.fields = fields
        self.replace = replace
    }

    enum CodingKeys: String, CodingKey {
        case name, clipIDs, clips, from, to, fields, replace
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let ids = (try c.decodeList(.clipIDs) ?? []) + (try c.decodeList(.clips) ?? [])
        clipIDs = ids.isEmpty ? nil : ids
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        replace = try c.decodeIfPresent(Bool.self, forKey: .replace)
        // A field is {"clipID": ..., "label": ...}, or "clip_x" or
        // "clip_x=Label" as the CLI takes it.
        if let objects = try? c.decodeIfPresent([SegmentMaker.Field].self, forKey: .fields) {
            fields = objects
        } else if let texts = try c.decodeList(.fields) {
            fields = texts.map(SegmentMaker.Field.parse)
        } else {
            fields = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(clipIDs, forKey: .clipIDs)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encodeIfPresent(to, forKey: .to)
        try c.encodeIfPresent(fields, forKey: .fields)
        try c.encodeIfPresent(replace, forKey: .replace)
    }

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> SegmentSaveResult {
        guard let project else { throw ServiceError(.badRequest, "Saving a segment needs a project.") }
        return try await assets.saveSegment(self, project: project)
    }
}

extension SegmentMaker.Field {
    /// `clip_x` or `clip_x=Label`.
    public static func parse(_ text: String) -> SegmentMaker.Field {
        let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return SegmentMaker.Field(clipID: parts[0], label: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }
}

public struct SegmentSaveResult: Codable, Sendable {
    public var segment: SegmentSummary
    /// The clips it was made of.
    public var clipIDs: [String]
    /// Files copied beside it, by their names in its folder.
    public var copied: [String]
    /// What couldn't be carried over.
    public var notes: [String]
}

// MARK: - insert

public struct SegmentInsertRequest: AssetCall {
    public static let operation = AssetOperation.insertSegment
    public static var needsProject: Bool { true }
    /// The segment's name (or its folder's).
    public var name: String
    public var at: Time
    /// Words for its fields, by key; the rest get their defaults.
    public var values: [String: String]?
    /// `place` (default) fails where a track is taken, `overwrite` replaces
    /// what's there, `insert` pushes later clips right.
    public var mode: InsertMode?
    public var label: String?
    public var author: String?

    public init(name: String, at: Time, values: [String: String]? = nil, mode: InsertMode? = nil, label: String? = nil, author: String? = nil) {
        self.name = name
        self.at = at
        self.values = values
        self.mode = mode
        self.label = label
        self.author = author
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        guard let at = try c.decodeTime(.at) else { throw ServiceError(.badRequest, "insert needs at, the time it starts.") }
        self.at = at
        values = try c.decodeIfPresent([String: String].self, forKey: .values)
        mode = try c.decodeIfPresent(InsertMode.self, forKey: .mode)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
    }

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> SegmentInsertResult {
        guard let project else { throw ServiceError(.badRequest, "Inserting a segment needs a project.") }
        return try await assets.insertSegment(self, project: project)
    }
}

public struct SegmentInsertResult: Codable, Sendable {
    public var segment: SegmentSummary
    public var at: Time
    public var applied: ApplyResult
}

// MARK: - The service

extension AssetService {
    /// The shared library's segments.
    public var segmentStore: SegmentStore {
        SegmentStore(library: library.sharedLibrary)
    }

    public func segments() -> SegmentListResult {
        let store = segmentStore
        let (segments, problems) = store.list()
        return SegmentListResult(folder: store.folder.path, exists: store.library.exists, segments: segments.map(\.summary), problems: problems)
    }

    public func saveSegment(_ request: SegmentSaveRequest, project client: ProjectClient) async throws -> SegmentSaveResult {
        let (project, _) = try await read(client)
        let folder = ProjectFolder(projectFile: client.projectURL)
        let ids: [String]
        if let given = request.clipIDs {
            ids = given
        } else if request.from != nil || request.to != nil {
            let from = request.from ?? .zero
            let to = request.to ?? project.duration
            ids = project.allTracks.flatMap(\.clips).filter { $0.start >= from && $0.end <= to }.map(\.id)
            guard !ids.isEmpty else {
                throw ServiceError(.notFound, "No clip lies wholly between \(from) and \(to).")
            }
        } else {
            throw ServiceError(.badRequest, "Say which clips to save: clipIDs, or from and to.")
        }
        let draft = try SegmentMaker.draft(name: request.name, clipIDs: ids, in: project, folder: folder, fields: request.fields ?? [], assetsRoot: library.root)
        let store = segmentStore
        let stored = try await ProjectArchiver.onBackgroundThread { try store.save(draft, replace: request.replace ?? false) }
        return SegmentSaveResult(segment: stored.summary, clipIDs: ids, copied: draft.files.map(\.name), notes: draft.segment.notes)
    }

    public func insertSegment(_ request: SegmentInsertRequest, project client: ProjectClient) async throws -> SegmentInsertResult {
        let stored = try segmentStore.load(request.name)
        let missing = stored.missingFiles
        guard missing.isEmpty else {
            throw ServiceError(.notFound, "\(stored.name) is missing \(missing.joined(separator: ", ")) from \(stored.folder.path), so it wasn't inserted.")
        }
        let known = Set(stored.segment.template.fields.map(\.key))
        if let unknown = request.values?.keys.sorted().first(where: { !known.contains($0) }) {
            let fields = known.isEmpty ? "It has no fields." : "Its fields: \(known.sorted().joined(separator: ", "))."
            throw ServiceError(.badRequest, "\(stored.name) has no field \"\(unknown)\". \(fields)")
        }
        let batch = stored.insertBatch(at: request.at, values: request.values ?? [:], mode: request.mode ?? .place, label: request.label)
        let applied = try await client.call(ApplyRequest(label: batch.label, author: request.author, commands: batch.commands))
        return SegmentInsertResult(segment: stored.summary, at: request.at, applied: applied)
    }
}

// MARK: - Text

extension SegmentSummary {
    /// "5.200 s, 4 clips on Graphics, Text and SFX; asks for title".
    var line: String {
        var parts = ["\(CommandText.number(duration.seconds)) s, \(clips) clip\(clips == 1 ? "" : "s") on \(Self.list(tracks))"]
        if !fields.isEmpty { parts.append("asks for \(Self.list(fields.map(\.key)))") }
        if !missing.isEmpty { parts.append("MISSING \(missing.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

extension SegmentListResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if !exists {
            lines.append("There's no shared library at \((folder as NSString).deletingLastPathComponent) yet. Tandem makes it when it opens; `tandem segments save` makes it too.")
        } else if segments.isEmpty {
            lines.append("No segments in \(ByteText.home(folder)) yet. Save one from the timeline (Timeline > Save selection as segment) or with tandem segments save \"Intro\" --clips clip_a,clip_b.")
        } else {
            lines.append("Segments in \(ByteText.home(folder)) (\(segments.count)):")
            let width = min(segments.map(\.name.count).max() ?? 0, 32)
            for segment in segments {
                lines.append("  \(segment.name.padding(toLength: max(width, segment.name.count), withPad: " ", startingAt: 0))  \(segment.line)")
            }
            lines.append("Put one on the timeline with tandem segments insert \"<name>\" --at <time> (--value key=text fills a field).")
        }
        for problem in problems { lines.append("Warning: \(problem)") }
        return lines.joined(separator: "\n")
    }
}

extension SegmentSaveResult: ReadableResult {
    public var readableText: String {
        var lines = ["Saved the segment \"\(segment.name)\" (\(segment.line)) to \(ByteText.home(segment.folder))."]
        if copied.isEmpty {
            lines.append("It plays no files, so nothing was copied.")
        } else {
            lines.append("Copied beside it, so it stands on its own: \(copied.joined(separator: ", ")).")
        }
        for note in notes { lines.append("Note: \(note)") }
        lines.append("Insert it with tandem segments insert \"\(segment.name)\" --at <time>.")
        return lines.joined(separator: "\n")
    }
}

extension SegmentInsertResult: ReadableResult {
    public var readableText: String {
        var lines = ["Put the segment \"\(segment.name)\" at \(at) as revision \(applied.revision) (\(CommandText.number(segment.duration.seconds)) s, one undo step)."]
        let clips = applied.createdIDs.filter { $0.hasPrefix("clip_") }
        if !clips.isEmpty { lines.append("Clips, linked: \(clips.joined(separator: ", ")).") }
        lines.append("Its files are used where they are in \(ByteText.home(segment.folder)); archiving the project copies them in.")
        for warning in applied.warnings { lines.append("Warning: \(warning)") }
        return lines.joined(separator: "\n")
    }
}
