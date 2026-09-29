import Foundation
import TandemAssets
import TandemCore
import TandemMedia

// Archiving: making a project folder standalone, so it opens on another
// Mac (Bruce, the archive server) with nothing missing. `ProjectArchiver`
// does the work; this file is what the CLI, MCP, HTTP and the app see.

public enum ArchiveMode: String, Codable, Sendable {
    /// Copies what the project uses from outside its folder into it and
    /// points the project at the copies.
    case consolidate
    /// Writes a standalone copy of the whole project folder somewhere else,
    /// leaving the original as it is.
    case archive
}

/// What a file in an archive is.
public enum ArchivedKind: String, Codable, Sendable {
    case media
    case lut
    case font
    /// A record-it `<base>.take.json`, copied beside its take so the files
    /// stay lined up.
    case sidecar
    /// One of the project folder's own files (archive mode).
    case folder
}

/// A file the archive brought in from outside the project folder.
public struct ArchivedFile: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// A dry run: this is where it would go.
        case planned
        /// An APFS clone: instant, and no extra space until one side changes.
        case cloned
        case copied
        /// Already there with the same content, so not copied again.
        case reused
    }

    public var kind: ArchivedKind
    /// Where the file's bytes were.
    public var original: String
    /// Where it is now, relative to the archived folder.
    public var path: String
    public var bytes: Int64
    public var sha256: String?
    public var outcome: Outcome
    /// What uses it: media IDs (`<id> motion clip` for a Live Photo's
    /// movie), `clipID effectID` for a clip's LUT, a font family.
    public var usedBy: [String]
}

/// Something the project uses that isn't there. It's left as it is and the
/// rest is archived.
public struct MissingFile: Codable, Equatable, Sendable {
    public var kind: ArchivedKind
    /// The path as the project has it, or a font's family name.
    public var path: String
    public var usedBy: [String]
    /// Clips that play it or use it.
    public var clips: Int
}

public struct ArchivedFont: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Comes with macOS, so every Mac has it.
        case system
        /// Already in the project's `assets/font/`.
        case inProject
        /// Copied into `assets/font/`.
        case collected
        /// Not installed here; titles using it fall back to SF Pro.
        case missing
    }

    public var family: String
    public var status: Status
    /// Where a collected font's files came from.
    public var files: [String]
}

/// A top-level file or folder of the project folder, and what an archive
/// copies of it.
public struct FolderPart: Codable, Equatable, Sendable {
    /// `source/` for a folder, `notes.md` for a file.
    public var path: String
    public var files: Int
    public var bytes: Int64
}

/// Part of the project folder an archive leaves out, and why.
public struct LeftOut: Codable, Equatable, Sendable {
    public var path: String
    public var why: String
    public var files: Int
    public var bytes: Int64
}

/// Another project file in the same folder (a version), made standalone
/// too.
public struct OtherProjectFile: Codable, Equatable, Sendable {
    public var file: String
    /// References pointed at their new place.
    public var rewritten: Int
    /// Why it was left as it is, when it was.
    public var note: String?
}

public struct ArchiveResult: Codable, Sendable {
    public var mode: ArchiveMode
    public var dryRun: Bool
    /// The project file that was archived.
    public var project: String
    /// The folder that's standalone now: the project's own (consolidate)
    /// or the new copy (archive).
    public var folder: String
    /// The standalone project file.
    public var projectFile: String
    /// Files brought in from outside the project folder.
    public var collected: [ArchivedFile]
    /// References to files inside the folder that were written as absolute
    /// paths, now relative.
    public var madeRelative: Int
    /// Archive mode: the project folder's own files, copied as they are.
    public var folderFiles: Int
    public var folderBytes: Int64
    /// Archive mode: the same by top-level folder.
    public var folderParts: [FolderPart]
    /// Files this run copied (or would copy), and their bytes.
    public var copiedFiles: Int
    public var copiedBytes: Int64
    /// Files already in place with the same content, so not copied again.
    public var reusedFiles: Int
    public var missing: [MissingFile]
    public var fonts: [ArchivedFont]
    public var leftOut: [LeftOut]
    public var otherProjects: [OtherProjectFile]
    /// `archive.json`, which says where every file came from.
    public var manifest: String?
    /// Consolidate: the project's revision once its paths were rewritten.
    public var revision: Int?
    public var warnings: [String]
}

/// How far an archive has got, for a progress bar.
public struct ArchiveProgress: Equatable, Sendable {
    public var message: String
    /// 0 to 1.
    public var fraction: Double
    public var filesDone: Int
    public var filesTotal: Int

    public init(message: String, fraction: Double, filesDone: Int, filesTotal: Int) {
        self.message = message
        self.fraction = fraction
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }
}

public struct ArchiveOptions: Sendable {
    /// Where to write a standalone copy: the archive is a folder named
    /// after the project's folder, inside this one. Nil makes the project's
    /// own folder standalone instead.
    public var destination: URL?
    /// Archive mode: also copy proxies, mattes, thumbnails and isolated
    /// voice, which Tandem otherwise rebuilds when the archive is opened.
    public var withCache: Bool
    /// Work out what would happen and change nothing.
    public var dryRun: Bool
    /// The undo label for the edit that points the project at the copies.
    public var label: String?
    /// Who that edit is credited to.
    public var author: String
    /// Finds the files of fonts titles use.
    public var fonts: any FontLocating
    /// The shared library. Its files are brought in like any other file
    /// from outside the folder, into `media/Tandem Library/<where they
    /// were in it>`, and so are the asset library's converted copies of
    /// them (a WebM sticker plays from one), named after the sticker.
    public var sharedLibrary: SharedLibrary?
    /// The asset library, where those converted copies are.
    public var assetsRoot: URL?
    /// Tests turn clones off to take the copy path a network share takes.
    var clone = true

    public init(
        destination: URL? = nil, withCache: Bool = false, dryRun: Bool = false, label: String? = nil, author: String = "user",
        fonts: any FontLocating = InstalledFonts(), sharedLibrary: SharedLibrary? = SharedLibrary.locate(), assetsRoot: URL? = AssetLibrary.root()
    ) {
        self.destination = destination
        self.withCache = withCache
        self.dryRun = dryRun
        self.label = label
        self.author = author
        self.fonts = fonts
        self.sharedLibrary = sharedLibrary
        self.assetsRoot = assetsRoot
    }
}

// MARK: - The service call

public struct ArchiveRequest: ServiceCall {
    public static let operation = ServiceOperation.archive
    /// Write a standalone copy of the project folder inside this folder
    /// (absolute, or relative to the project folder). Leave out to make the
    /// project's own folder standalone.
    public var to: String?
    /// Archive mode: keep proxies, mattes, thumbnails and isolated voice.
    public var withCache: Bool?
    /// List what would be copied, and the sizes, without changing anything.
    public var dryRun: Bool?
    public var label: String?
    public var author: String?

    public init(to: String? = nil, withCache: Bool? = nil, dryRun: Bool? = nil, label: String? = nil, author: String? = nil) {
        self.to = to
        self.withCache = withCache
        self.dryRun = dryRun
        self.label = label
        self.author = author
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ArchiveResult {
        try await service.archive(self, context: context)
    }
}

extension TandemService {
    /// Archives the open project. The copying runs on a thread of its own,
    /// and cancelling the calling task stops it between chunks; what was
    /// copied stays, hidden, for the next run to pick up.
    public func archive(_ request: ArchiveRequest, context: CallContext) async throws -> ArchiveResult {
        let shared = locateSharedLibrary()
        let options = ArchiveOptions(
            destination: request.to.map(outputURL),
            withCache: request.withCache ?? false,
            dryRun: request.dryRun ?? false,
            label: request.label,
            author: request.author ?? context.author,
            fonts: InstalledFonts(sharedLibrary: shared?.root),
            sharedLibrary: shared
        )
        let control = ArchiveControl()
        let archiver = ProjectArchiver(session: session, options: options, control: control, applyEdit: { [self] batch in
            try self.apply(ApplyRequest(batch: batch), context: context).revision
        })
        return try await withTaskCancellationHandler {
            try await ProjectArchiver.onBackgroundThread { try archiver.run() }
        } onCancel: {
            control.cancel()
        }
    }
}

// MARK: - Text

extension ArchiveResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let name = (project as NSString).lastPathComponent
        let outside = Self.files(collected.count)
        let collectedBytes = collected.filter { $0.outcome != .reused }.reduce(Int64(0)) { $0 + $1.bytes }
        let nothingToDo = collected.isEmpty && madeRelative == 0
        let brought = collected.filter { $0.outcome == .copied || $0.outcome == .cloned }
        let how: String
        if !brought.isEmpty, brought.allSatisfy({ $0.outcome == .cloned }) {
            how = ", as clones that take no extra space"
        } else {
            how = ""
        }
        let already = reusedFiles > 0 ? "; \(reusedFiles) were already there" : ""
        switch (mode, dryRun) {
        case (.consolidate, _) where nothingToDo:
            lines.append("\(name) is \(dryRun ? "" : "now ")standalone: every file it uses is in its folder, \(folder).")
        case (.consolidate, true):
            lines.append("Dry run, nothing changed. Making \(name) standalone would bring in \(outside) from outside its folder (\(ByteText.size(collectedBytes))).")
        case (.consolidate, false):
            lines.append("\(name) is standalone: brought in \(outside) from outside its folder (\(ByteText.size(collectedBytes))\(how)\(already)).")
        case (.archive, true):
            lines.append("Dry run, nothing changed. Archiving \(name) would write a standalone copy to \(folder): the project folder (\(Self.files(folderFiles)), \(ByteText.size(folderBytes))) and \(outside) from outside it (\(ByteText.size(collectedBytes))).")
        case (.archive, false):
            lines.append("Archived \(name) to \(folder), a standalone copy; the original is as it was. Copied \(Self.files(copiedFiles)) (\(ByteText.size(copiedBytes)))\(already).")
        }
        if mode == .archive, !folderParts.isEmpty {
            lines.append("The project folder\(dryRun ? "" : "'s files"):")
            let width = min(folderParts.map(\.path.count).max() ?? 0, 40)
            for part in folderParts {
                let count = part.files == 1 ? "1 file" : "\(part.files) files"
                lines.append("  \(part.path.padding(toLength: max(width, part.path.count), withPad: " ", startingAt: 0))  \(count), \(ByteText.size(part.bytes))")
            }
        }
        if !collected.isEmpty {
            lines.append(dryRun ? "From outside the folder:" : "Brought in:")
            for file in collected.prefix(40) {
                let how = file.outcome == .planned ? "" : "  \(file.outcome.rawValue)"
                lines.append("  \(file.path)  \(ByteText.size(file.bytes))\(how)  from \(ByteText.home(file.original))")
            }
            if collected.count > 40 { lines.append("  ... and \(collected.count - 40) more (--json lists them all)") }
        }
        if madeRelative > 0 {
            lines.append("\(madeRelative) path\(madeRelative == 1 ? "" : "s") inside the folder \(dryRun ? "would be" : "were") made relative.")
        }
        let fontLines = fonts.filter { $0.status == .collected }.map { "\($0.family) (from \($0.files.map { ByteText.home($0) }.joined(separator: ", ")))" }
        if !fontLines.isEmpty { lines.append("Fonts copied into assets/font: \(fontLines.joined(separator: "; ")).") }
        if !missing.isEmpty {
            lines.append("Missing, so left as they are (\(missing.count)):")
            for item in missing {
                switch item.kind {
                case .font:
                    lines.append("  font \"\(item.path)\" isn't installed here; \(item.clips) title\(item.clips == 1 ? "" : "s") use it and fall back to SF Pro")
                default:
                    let users = item.clips > 0 ? ", \(item.clips) clip\(item.clips == 1 ? "" : "s")" : ""
                    lines.append("  \(item.path)  (\(item.usedBy.joined(separator: ", "))\(users))")
                }
            }
        }
        for part in leftOut {
            let size = part.bytes > 0 ? " (\(ByteText.size(part.bytes)))" : ""
            lines.append("Left out \(part.path)\(size): \(part.why)")
        }
        for other in otherProjects {
            if let note = other.note {
                lines.append("\(other.file): \(note)")
            } else if other.rewritten > 0 {
                lines.append("\(other.file): \(other.rewritten) path\(other.rewritten == 1 ? "" : "s") pointed at the copies too.")
            }
        }
        for warning in warnings { lines.append("Warning: \(warning)") }
        if dryRun {
            if mode == .archive {
                lines.append("Run it without --dry-run (dryRun: false) to write the archive.")
            } else if !nothingToDo {
                lines.append("Run it without --dry-run (dryRun: false) to copy them in, or pass --to <folder> to write a standalone copy somewhere else instead.")
            }
        } else {
            if let revision, mode == .consolidate, !nothingToDo { lines.append("The project is at revision \(revision); `tandem undo` points it back at the old paths (the copies stay).") }
            if let manifest { lines.append("Manifest: \(manifest)") }
        }
        return lines.joined(separator: "\n")
    }
}

extension ArchiveResult {
    static func files(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }
}

/// Sizes and paths for people.
enum ByteText {
    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// `~/...` for paths in the home folder.
    static func home(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
