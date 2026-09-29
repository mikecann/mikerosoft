import Foundation
import TandemCore
import TandemMedia

/// Finding media files that aren't where the project says: a project opened
/// on another Mac, or a folder tidied by hand. The folder scan already
/// follows a file renamed inside the project folder (by content); this
/// looks for files by name in the project folder and in folders Mike picks,
/// and takes one when its content matches what the project knew.
public enum MediaRelinker {
    public struct Match: Codable, Equatable, Sendable {
        public var mediaID: String
        /// The path the project had.
        public var from: String
        /// The path it gets: relative when the file is in the project folder.
        public var to: String
    }

    /// Media whose files aren't there.
    public static func missing(in project: Project, folder: ProjectFolder) -> [MediaItem] {
        project.media.filter { FileCopier.fileInfo(folder.url(for: $0)) == nil }
    }

    /// Looks for each item's file by name in `folders` and their subfolders,
    /// earlier folders first. A file whose content matches the item's
    /// fingerprint (its size and a hash of both ends) is taken; an item
    /// without a fingerprint takes the only file of that name, and one with
    /// several to choose from is listed in `ambiguous`.
    public static func search(for items: [MediaItem], in folders: [URL], folder: ProjectFolder, control: ArchiveControl? = nil) -> (found: [Match], ambiguous: [String]) {
        guard !items.isEmpty else { return ([], []) }
        let names = Set(items.map { ($0.path as NSString).lastPathComponent.lowercased() })
        var candidates: [String: [URL]] = [:]
        var budget = 500_000
        for root in folders {
            collect(names, under: root, into: &candidates, budget: &budget, control: control)
        }
        var found: [Match] = []
        var ambiguous: [String] = []
        for item in items {
            let files = candidates[(item.path as NSString).lastPathComponent.lowercased()] ?? []
            var chosen: URL?
            if let known = item.fingerprint.flatMap(Fingerprint.init) {
                chosen = files.first { file in
                    guard FileCopier.fileInfo(file)?.size == known.size, let print = try? Fingerprint.compute(for: file) else { return false }
                    return print.contentID == known.contentID
                }
            } else if files.count == 1 {
                chosen = files[0]
            } else if files.count > 1 {
                ambiguous.append(item.path)
            }
            if let chosen {
                found.append(Match(mediaID: item.id, from: item.path, to: storedPath(for: chosen, in: folder)))
            }
        }
        return (found, ambiguous)
    }

    /// Looks in `folders` first, then in `fallback` (the shared library) for
    /// what they didn't have. A file with several candidates in the first
    /// folders stays undecided rather than being settled by the fallback.
    public static func search(for items: [MediaItem], in folders: [URL], then fallback: [URL], folder: ProjectFolder, control: ArchiveControl? = nil) -> (found: [Match], ambiguous: [String]) {
        var (found, ambiguous) = search(for: items, in: folders, folder: folder, control: control)
        let settled = Set(found.map(\.mediaID))
        let rest = items.filter { !settled.contains($0.id) && !ambiguous.contains($0.path) }
        guard !rest.isEmpty, !fallback.isEmpty else { return (found, ambiguous) }
        let more = search(for: rest, in: fallback, folder: folder, control: control)
        found += more.found
        ambiguous += more.ambiguous
        return (found, ambiguous)
    }

    /// The path to store for a file: relative when it's in the project
    /// folder, however the folder is spelled (`/var` or `/private/var`).
    static func storedPath(for file: URL, in folder: ProjectFolder) -> String {
        let spelled = folder.path(for: file)
        guard spelled.hasPrefix("/"), let real = ProjectArchiver.realPath(file), let root = ProjectArchiver.realPath(folder.root),
              ProjectArchiver.isInside(real, root) else { return spelled }
        return String(real.dropFirst(root.count + 1))
    }

    /// Files under `root` with one of `names` (lower-cased), skipping hidden
    /// folders and npm packages.
    static func collect(_ names: Set<String>, under root: URL, into found: inout [String: [URL]], budget: inout Int, control: ArchiveControl?) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in enumerator {
            budget -= 1
            if budget <= 0 || control?.isCancelled == true { return }
            let name = url.lastPathComponent
            if name == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            let key = name.lowercased()
            guard names.contains(key), FileCopier.fileInfo(url) != nil else { continue }
            let file = url.standardizedFileURL
            if !(found[key] ?? []).contains(file) { found[key, default: []].append(file) }
        }
    }

    /// The edit that points each match's media at its file.
    public static func commands(for matches: [Match]) -> [EditCommand] {
        matches.map { .updateMedia(mediaID: $0.mediaID, patch: .object(["path": .string($0.to)])) }
    }
}

// MARK: - The service call

public struct RelinkRequest: ServiceCall {
    public static let operation = ServiceOperation.relink
    /// Folders to look in as well as the project's own, subfolders
    /// included. Absolute, or relative to the project folder.
    public var search: [String]?
    /// Say what would be relinked without changing anything.
    public var dryRun: Bool?
    public var label: String?
    public var author: String?

    public init(search: [String]? = nil, dryRun: Bool? = nil, label: String? = nil, author: String? = nil) {
        self.search = search
        self.dryRun = dryRun
        self.label = label
        self.author = author
    }

    public func run(on service: TandemService, context: CallContext) async throws -> RelinkResult {
        try await service.relink(self, context: context)
    }
}

public struct RelinkedMedia: Codable, Equatable, Sendable {
    public var mediaID: String
    public var from: String
    public var to: String
}

public struct StillMissing: Codable, Equatable, Sendable {
    public var mediaID: String
    public var path: String
    /// Clips that play it.
    public var clips: Int
    /// True when several files have its name and nothing says which.
    public var ambiguous: Bool
}

public struct RelinkResult: Codable, Sendable {
    public var revision: Int
    public var dryRun: Bool
    /// Where it looked.
    public var searched: [String]
    public var relinked: [RelinkedMedia]
    public var missing: [StillMissing]
    public var applied: ApplyResult?
}

extension TandemService {
    public func relink(_ request: RelinkRequest, context: CallContext) async throws -> RelinkResult {
        let folder = self.folder
        let roots = [folder.root] + (request.search ?? []).map(outputURL)
        for root in roots.dropFirst() {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw ServiceError(.notFound, "There's no folder at \(root.path) to search.")
            }
        }
        let (project, revision) = coordinator.snapshot()
        let missing = MediaRelinker.missing(in: project, folder: folder)
        let control = ArchiveControl()
        // The shared library last: a project from another Mac finds its
        // stickers and sounds in this Mac's library.
        let fallback: [URL]
        if let shared = locateSharedLibrary(), shared.exists,
           !roots.contains(where: { $0.standardizedFileURL.path == shared.root.path }) {
            fallback = [shared.root]
        } else {
            fallback = []
        }
        let (found, ambiguous) = try await withTaskCancellationHandler {
            try await ProjectArchiver.onBackgroundThread { MediaRelinker.search(for: missing, in: roots, then: fallback, folder: folder, control: control) }
        } onCancel: {
            control.cancel()
        }
        var clipCounts: [String: Int] = [:]
        for clip in project.allTracks.flatMap(\.clips) {
            if let id = clip.mediaID { clipCounts[id, default: 0] += 1 }
        }
        let relinkedIDs = Set(found.map(\.mediaID))
        var result = RelinkResult(
            revision: revision,
            dryRun: request.dryRun == true,
            searched: (roots + (missing.isEmpty ? [] : fallback)).map(\.path),
            relinked: found.map { RelinkedMedia(mediaID: $0.mediaID, from: $0.from, to: $0.to) },
            missing: missing.filter { !relinkedIDs.contains($0.id) }.map {
                StillMissing(mediaID: $0.id, path: $0.path, clips: clipCounts[$0.id] ?? 0, ambiguous: ambiguous.contains($0.path))
            },
            applied: nil
        )
        guard !found.isEmpty, request.dryRun != true else { return result }
        // Worked out again if the project changes meanwhile; media relinked
        // or removed in the meantime is left alone.
        for attempt in 1...5 {
            let (current, now) = coordinator.snapshot()
            let still = found.filter { current.media($0.mediaID)?.path == $0.from }
            guard !still.isEmpty else { break }
            let label = request.label ?? "Relink \(still.count) missing file\(still.count == 1 ? "" : "s")"
            do {
                result.applied = try apply(ApplyRequest(label: label, author: request.author, commands: MediaRelinker.commands(for: still), expectedRevision: now), context: context)
                break
            } catch let error as ServiceError where error.knownCode == .staleRevision && attempt < 5 {
                continue
            }
        }
        result.revision = coordinator.revision
        return result
    }
}

extension RelinkResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let total = relinked.count + missing.count
        if total == 0 {
            lines.append("Nothing's missing: every media file is where the project says.")
            return lines.joined(separator: "\n")
        }
        if relinked.isEmpty {
            lines.append("Found none of the \(total) missing file\(total == 1 ? "" : "s").")
        } else {
            let verb = dryRun ? "Would relink" : (applied == nil ? "Found" : "Relinked")
            lines.append("\(verb) \(relinked.count) of \(total) missing file\(total == 1 ? "" : "s")\(applied.map { " as revision \($0.revision)" } ?? ""):")
            for item in relinked { lines.append("  \(item.mediaID)  \(item.from) -> \(item.to)") }
        }
        if !missing.isEmpty {
            lines.append("Still missing (\(missing.count)):")
            for item in missing {
                let clips = item.clips == 1 ? "1 clip" : "\(item.clips) clips"
                let why = item.ambiguous ? "; several files have that name, so pick the right one's folder with --search" : ""
                lines.append("  \(item.mediaID)  \(item.path)  (\(clips))\(why)")
            }
        }
        lines.append("Searched: \(searched.map { ByteText.home($0) }.joined(separator: ", ")).")
        if dryRun, !relinked.isEmpty { lines.append("Nothing changed yet. Run it without --dry-run to relink them.") }
        if !missing.isEmpty { lines.append("Add a folder to look in with --search <folder> (MCP and HTTP: search: [\"...\"]).") }
        return lines.joined(separator: "\n")
    }
}
