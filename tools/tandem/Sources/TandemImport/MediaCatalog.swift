import Foundation
import TandemCore
import TandemMedia

/// Where to look for media that isn't where the source project says, and
/// how to probe it.
public struct MediaLocating: Sendable {
    public var prober: any MediaProbing
    /// Old path prefix to new, tried in order when a file isn't where the
    /// project says, for projects saved on another Mac.
    public var pathRewrites: [PathRewrite]
    /// Folders searched by file name (and one level down) for media that
    /// has moved.
    public var searchFolders: [URL]
    /// Where to put links to files whose extension AVFoundation won't open
    /// (Filmora keeps some library MP3s as `.cof`). The project refers to
    /// the link. Nil keeps the original path and reports it.
    public var aliasFolder: URL?

    public struct PathRewrite: Sendable, Equatable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public init(
        prober: any MediaProbing = AVFoundationProbe(),
        pathRewrites: [PathRewrite] = [],
        searchFolders: [URL] = [],
        aliasFolder: URL? = nil
    ) {
        self.prober = prober
        self.pathRewrites = pathRewrites
        self.searchFolders = searchFolders
        self.aliasFolder = aliasFolder
    }

    /// Projects from TinkerDesk, the other Mac, keep media under its home
    /// folder. This rewrite points them at the same place here.
    public static let tinkerDeskHome = PathRewrite(from: "/Users/mikeysee/", to: NSHomeDirectory() + "/")
}

/// One `MediaItem` per file for an import. Resolves where each file is
/// now, probes it once and remembers the answer.
final class MediaCatalog {
    enum Outcome {
        case found(MediaItem)
        /// Not on disk. The item uses the source project's own facts about
        /// the file so the clip survives and can be relinked later.
        case offline(MediaItem)
        /// Present but unusable (WebM stickers), or missing with nothing
        /// known about it. The reason is already reported.
        case unusable
    }

    let locating: MediaLocating
    private(set) var items: [MediaItem] = []
    private var outcomes: [String: Outcome] = [:]
    private var ids = ImportIDs.Allocator()
    private var linkedNames = Set<String>()

    init(locating: MediaLocating) {
        self.locating = locating
    }

    /// The item for a file the source project refers to.
    ///
    /// - Parameters:
    ///   - path: the path as the source project has it.
    ///   - role: what the file is for, when the importer knows better than
    ///     the file name does.
    ///   - fallback: what the source project says about the file, used when
    ///     it can't be found.
    func resolve(
        _ path: String,
        role: MediaRole? = nil,
        fallback: ProbedMedia? = nil,
        report: inout ImportReport,
        at time: Time? = nil
    ) async -> Outcome {
        if let known = outcomes[path] { return known }
        let outcome = await lookUp(path, role: role, fallback: fallback, report: &report, at: time)
        outcomes[path] = outcome
        switch outcome {
        case .found(let item), .offline(let item): items.append(item)
        case .unusable: break
        }
        return outcome
    }

    func item(forPath path: String) -> MediaItem? {
        switch outcomes[path] {
        case .found(let item), .offline(let item): return item
        default: return nil
        }
    }

    // MARK: - Finding files

    private func lookUp(_ path: String, role: MediaRole?, fallback: ProbedMedia?, report: inout ImportReport, at time: Time?) async -> Outcome {
        let name = (path as NSString).lastPathComponent
        var lastError: Error?
        for candidate in candidates(for: path) where locating.prober.exists(candidate) {
            do {
                let probed = try await locating.prober.probe(candidate)
                let usable = link(candidate, report: &report)
                if candidate.path != path {
                    report.add(.note, "media", "Found \(name) at \(candidate.path) instead of \(path).")
                }
                if probed.animatedImage {
                    report.add(.approximated, "media", "\(name) is an animated image; Tandem shows its first frame.", at: time)
                }
                return .found(makeItem(path: usable.path, key: path, probed: probed, role: role))
            } catch {
                lastError = error
            }
        }
        if let lastError {
            report.add(.unsupported, "media", "\(name) can't be used: \(lastError)", at: time)
            return .unusable
        }
        if let fallback {
            report.add(.missingMedia, "media", "\(path) wasn't found. The clips are kept offline with the length the project recorded.", at: time)
            return .offline(makeItem(path: path, key: path, probed: fallback, role: role))
        }
        report.add(.missingMedia, "media", "\(path) wasn't found, so its clips were left out.", at: time)
        return .unusable
    }

    /// The original path, then each rewrite, then the file name in each
    /// search folder and its immediate subfolders.
    func candidates(for path: String) -> [URL] {
        var result = [URL(fileURLWithPath: path)]
        for rewrite in locating.pathRewrites where path.hasPrefix(rewrite.from) {
            result.append(URL(fileURLWithPath: rewrite.to + path.dropFirst(rewrite.from.count)))
        }
        let name = (path as NSString).lastPathComponent
        let fm = FileManager.default
        for folder in locating.searchFolders {
            result.append(folder.appendingPathComponent(name))
            let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result.append(child.appendingPathComponent(name))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Files AVFoundation can't open by extension get a symlink with the
    /// right one, when there's a folder for links.
    private func link(_ url: URL, report: inout ImportReport) -> URL {
        let ext = url.pathExtension.lowercased()
        guard !FileSniffer.avFoundationExtensions.contains(ext),
              let sniffed = FileSniffer.sniff(url),
              sniffed.kind != .image,
              sniffed.fileExtension != ext else { return url }
        guard let folder = locating.aliasFolder else {
            report.add(.approximated, "media", "\(url.lastPathComponent) is really a .\(sniffed.fileExtension) file; players that go by extension won't open it.")
            return url
        }
        // Library files are often all called downloadCommonCfg.cof, so the
        // link is named after the folder that holds them.
        var base = url.deletingPathExtension().lastPathComponent
        if base == "downloadCommonCfg" || base.isEmpty {
            let parent = url.deletingLastPathComponent()
            base = parent.lastPathComponent == "Data" ? parent.deletingLastPathComponent().lastPathComponent : parent.lastPathComponent
        }
        var linkName = "\(base).\(sniffed.fileExtension)"
        var counter = 2
        while linkedNames.contains(linkName) {
            linkName = "\(base) \(counter).\(sniffed.fileExtension)"
            counter += 1
        }
        linkedNames.insert(linkName)
        let target = folder.appendingPathComponent(linkName)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil || fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.createSymbolicLink(at: target, withDestinationURL: url)
            report.add(.note, "media", "Linked \(url.lastPathComponent) as \(linkName) so AVFoundation can open it by extension.")
            return target
        } catch {
            report.add(.approximated, "media", "Couldn't link \(url.lastPathComponent) with a .\(sniffed.fileExtension) name: \(error.localizedDescription)")
            return url
        }
    }

    private func makeItem(path: String, key: String, probed: ProbedMedia, role: MediaRole?) -> MediaItem {
        var guessed = role ?? MediaScanner.role(forPath: path)
        if probed.kind == .audio, [.camera, .screen, .broll, .graphic].contains(guessed) { guessed = .other }
        if probed.kind == .image, role == nil { guessed = .image }
        return MediaItem(
            id: ids.make("med", key: key),
            path: path,
            kind: probed.kind,
            role: guessed,
            duration: probed.kind == .image ? nil : probed.duration,
            frameRate: probed.frameRate,
            width: probed.width,
            height: probed.height,
            hasVideo: probed.hasVideo || probed.kind == .image,
            hasAudio: probed.hasAudio,
            hasAlpha: probed.hasAlpha,
            variableFrameRate: probed.variableFrameRate
        )
    }
}
