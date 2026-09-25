import Foundation
import TandemCore

/// Finds media in a project folder and describes it.
public enum MediaScanner {
    /// File extensions Tandem treats as media.
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    public static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp"]

    /// Folders that never hold project media. Hidden folders (a leading dot)
    /// and Filmora's `*.wfp.dir` folders are skipped as well.
    public static let skippedFolderNames: Set<String> = [".tandem", "exports", "node_modules", ".build", ".git"]

    /// How many files are probed at once.
    static let probeConcurrency = 6

    /// Scans the folder for media, skipping `.tandem`, `exports`,
    /// `node_modules` and hidden folders. Known paths keep their IDs; new
    /// files get new items. record-it takes (`<base>-camera.mov` and
    /// `<base>-screen.mov`) share a take ID and carry take offsets.
    ///
    /// Returns every media file found (plus known files outside the folder
    /// that still exist). Known files that are gone are left out; use
    /// `scanReport` to get them, along with files that couldn't be read yet
    /// and anything worth telling Mike.
    public static func scan(_ folder: ProjectFolder, known: [MediaItem]) async throws -> [MediaItem] {
        try await scanReport(folder, known: known).items
    }

    /// Scans the folder like `scan` and says what happened.
    ///
    /// Matching: a known item keeps its ID when its path still exists, or,
    /// for a rename, when a new file has the same content (size and hash of
    /// both ends). Unchanged files (same size and modification time) are not
    /// probed again, so rescanning a big folder is cheap.
    public static func scanReport(_ folder: ProjectFolder, known: [MediaItem]) async throws -> ScanReport {
        let files = mediaFiles(in: folder)
        var report = ScanReport()

        var knownByPath: [String: MediaItem] = [:]
        for item in known where knownByPath[item.path] == nil { knownByPath[item.path] = item }

        // Pair each file with the known item at the same path, if any.
        var work: [(url: URL, path: String, known: MediaItem?)] = []
        var claimed = Set<String>()
        for url in files {
            let path = folder.path(for: url)
            let match = knownByPath[path]
            if let match { claimed.insert(match.id) }
            work.append((url, path, match))
        }
        // Known files that live outside the folder are checked where they are.
        for item in known where !claimed.contains(item.id) && isOutside(item.path) {
            let url = folder.url(for: item)
            if FileManager.default.fileExists(atPath: url.path) {
                claimed.insert(item.id)
                work.append((url, item.path, item))
            }
        }
        var unclaimed = known.filter { !claimed.contains($0.id) }

        // Fingerprint and probe, a few files at a time.
        let outcomes = try await withThrowingTaskGroup(of: (Int, FileOutcome).self) { group in
            var results = [FileOutcome?](repeating: nil, count: work.count)
            var next = 0
            func add() {
                guard next < work.count else { return }
                let index = next
                let entry = work[index]
                next += 1
                group.addTask { (index, await examine(entry.url, path: entry.path, known: entry.known, folder: folder)) }
            }
            for _ in 0..<probeConcurrency { add() }
            while let (index, outcome) = try await group.next() {
                results[index] = outcome
                add()
            }
            return results.compactMap { $0 }
        }

        // New files first try to claim a vanished known item (a rename).
        var probed: [ProbedFile] = []
        for outcome in outcomes {
            switch outcome {
            case .ready(var file):
                if file.known == nil, let index = unclaimed.firstIndex(where: { renameMatches($0, file.fingerprint) }) {
                    let previous = unclaimed.remove(at: index)
                    file.item = relinked(previous, to: file)
                    file.known = previous
                    report.renamed.append(RenamedMedia(id: previous.id, from: previous.path, to: file.item.path))
                }
                probed.append(file)
            case .unchanged(let file):
                probed.append(file)
            case .skipped(let path, let reason, let known):
                report.skipped.append(SkippedMedia(path: path, reason: reason))
                // A known file that can't be read right now (being rewritten)
                // stays as it was rather than disappearing.
                if let known { probed.append(ProbedFile(item: known, fingerprint: nil, creationDate: nil, known: known)) }
            }
        }
        report.missing = unclaimed

        var items = probed.map(\.item)
        let pairing = await TakePairing.pair(items: &items, probed: probed, folder: folder)
        report.notes += pairing.notes
        report.items = items
        return report
    }

    /// Every media file under the folder, in path order.
    public static func mediaFiles(in folder: ProjectFolder) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder.root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if isSkippedFolder(name: url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard mediaKind(forPath: url.path) != nil else { continue }
            if values?.isSymbolicLink == true {
                // Follow links to files, never to folders (no loops).
                let target = url.resolvingSymlinksInPath()
                guard (try? target.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            } else if values?.isRegularFile != true {
                continue
            }
            found.append(url.standardizedFileURL)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// True for folders the scanner and watcher ignore.
    public static func isSkippedFolder(name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".") || skippedFolderNames.contains(lower) || lower.hasSuffix(".wfp.dir")
    }

    /// True when a path relative to the project folder is inside a skipped
    /// or hidden folder, or is a hidden file.
    public static func isSkippedPath(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let name = parts.last else { return true }
        if name.hasPrefix(".") { return true }
        return parts.dropLast().contains { isSkippedFolder(name: $0) }
    }

    /// The media kind a file extension implies, or nil for anything else.
    public static func mediaKind(forPath path: String) -> MediaKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }

    // MARK: - Roles

    /// Guesses what a file is for from its name and folder.
    ///
    /// In order: record-it names (`-camera`, `-screen`), the nearest folder
    /// that says what it holds (`music/`, `sfx/`, `broll/`, `graphics/`,
    /// `stickers/`), words in the file name, then the kind of file.
    public static func role(forPath path: String) -> MediaRole {
        roleGuess(forPath: path).role
    }

    /// `role(forPath:)` refined with what probing found: short audio that
    /// only guessed "music" from its extension is more likely a sound effect.
    public static func role(forPath path: String, kind: MediaKind, duration: Time?) -> MediaRole {
        let guess = roleGuess(forPath: path)
        if !guess.fromName, kind == .audio, let duration, duration.seconds < 10 { return .sfx }
        if !guess.fromName, kind == .audio { return .music }
        return guess.role
    }

    static func roleGuess(forPath path: String) -> (role: MediaRole, fromName: Bool) {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let isVideo = videoExtensions.contains(ext)
        let isAudio = audioExtensions.contains(ext)
        let isImage = imageExtensions.contains(ext)
        let words = Set(stem.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        // record-it take files.
        if isVideo || isAudio {
            if stem.hasSuffix("-camera") { return (.camera, true) }
            if stem.hasSuffix("-screen") { return (.screen, true) }
        }

        // The nearest folder that names its contents wins.
        let folders = (lower as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for folder in folders.reversed() {
            switch folder {
            case "music", "songs", "score", "beds": return (.music, true)
            case "sfx", "sounds", "sound effects", "sound-effects", "soundfx": return (.sfx, true)
            case "broll", "b-roll", "b roll", "b_roll": return (.broll, true)
            case "graphics", "motion-graphics", "motion graphics", "gfx", "overlays", "titles": return (.graphic, true)
            case "stickers": return (.sticker, true)
            default: continue
            }
        }

        if isVideo {
            if !words.isDisjoint(with: ["camera", "cam", "webcam", "facecam"]) { return (.camera, true) }
            if !words.isDisjoint(with: ["screen", "screencast", "screenrecording"]) { return (.screen, true) }
            if !words.isDisjoint(with: ["broll", "b-roll"]) || stem.contains("b-roll") { return (.broll, true) }
            if words.contains("sticker") { return (.sticker, true) }
            return (.other, false)
        }
        if isImage {
            if words.contains("sticker") { return (.sticker, true) }
            return (.image, false)
        }
        if isAudio {
            if !words.isDisjoint(with: ["sfx", "whoosh", "swoosh", "swipe", "click", "ding", "riser", "impact"]) { return (.sfx, true) }
            if !words.isDisjoint(with: ["music", "song", "bed", "score", "track"]) { return (.music, true) }
            return (.music, false)
        }
        return (.other, false)
    }

    // MARK: - Per file

    enum FileOutcome: Sendable {
        /// Probed afresh (new or changed file).
        case ready(ProbedFile)
        /// A known file whose size and modification time haven't changed.
        case unchanged(ProbedFile)
        case skipped(path: String, reason: String, known: MediaItem?)
    }

    static func examine(_ url: URL, path: String, known: MediaItem?, folder: ProjectFolder) async -> FileOutcome {
        // Unchanged known files keep everything they had.
        if let known, let stamp = known.fingerprint.flatMap(Fingerprint.init), stamp.matchesStat(of: url), known.hasProbeData {
            return .unchanged(ProbedFile(item: known, fingerprint: stamp, creationDate: nil, known: known))
        }
        do {
            let fingerprint = try Fingerprint.compute(for: url)
            let probe = try await MediaProbe.probe(url)
            var item: MediaItem
            if let known {
                item = known
                probe.apply(to: &item)
            } else {
                item = MediaItem(path: path, kind: probe.kind, role: .other)
                probe.apply(to: &item)
                item.role = role(forPath: path, kind: probe.kind, duration: probe.duration)
            }
            item.fingerprint = fingerprint.description
            return .ready(ProbedFile(item: item, fingerprint: fingerprint, creationDate: probe.creationDate, known: known))
        } catch {
            return .skipped(path: path, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)", known: known)
        }
    }

    static func renameMatches(_ item: MediaItem, _ fingerprint: Fingerprint?) -> Bool {
        guard let fingerprint, let old = item.fingerprint.flatMap(Fingerprint.init) else { return false }
        return old.contentID == fingerprint.contentID
    }

    /// A vanished known item moved to a new path: keep its ID, role, look
    /// and take, take the new path and the fresh probe.
    static func relinked(_ previous: MediaItem, to file: ProbedFile) -> MediaItem {
        var item = previous
        item.path = file.item.path
        item.kind = file.item.kind
        item.duration = file.item.duration
        item.frameRate = file.item.frameRate
        item.width = file.item.width
        item.height = file.item.height
        item.hasVideo = file.item.hasVideo
        item.hasAudio = file.item.hasAudio
        item.hasAlpha = file.item.hasAlpha
        item.variableFrameRate = file.item.variableFrameRate
        item.fingerprint = file.item.fingerprint
        return item
    }

    static func isOutside(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~/")
    }

    // MARK: - Probing

    /// Probes one file: duration, frame rate, size, streams, alpha, VFR.
    public static func probe(_ url: URL, folder: ProjectFolder, id: String? = nil) async throws -> MediaItem {
        let path = folder.path(for: url)
        let probe = try await MediaProbe.probe(url)
        var item = MediaItem(id: id ?? IDs.make("med"), path: path, kind: probe.kind, role: .other)
        probe.apply(to: &item)
        item.role = role(forPath: path, kind: probe.kind, duration: probe.duration)
        item.fingerprint = try Fingerprint.compute(for: url).description
        return item
    }
}

/// What a scan found, beyond the items themselves.
public struct ScanReport: Sendable {
    /// Every media file found, known IDs kept.
    public var items: [MediaItem] = []
    /// Known items whose files are gone (not at their path, not renamed).
    public var missing: [MediaItem] = []
    /// Known items that moved, matched by content.
    public var renamed: [RenamedMedia] = []
    /// Files that couldn't be read, usually because they're still being
    /// written. A later scan picks them up.
    public var skipped: [SkippedMedia] = []
    /// Things worth telling Mike, such as a take offset that was clamped.
    public var notes: [String] = []

    public init() {}
}

public struct RenamedMedia: Equatable, Sendable {
    public var id: String
    public var from: String
    public var to: String
}

public struct SkippedMedia: Equatable, Sendable {
    public var path: String
    public var reason: String
}

/// A scanned file with what pairing needs beyond the item.
struct ProbedFile: Sendable {
    var item: MediaItem
    var fingerprint: Fingerprint?
    /// From the file's metadata, when it was probed in this scan.
    var creationDate: Date?
    var known: MediaItem?
}

extension MediaItem {
    /// True when the item carries a probe's results, so an unchanged file
    /// doesn't need probing again.
    var hasProbeData: Bool {
        switch kind {
        case .image: return width != nil && height != nil
        case .audio: return duration != nil
        case .video: return duration != nil && width != nil && height != nil
        }
    }
}
