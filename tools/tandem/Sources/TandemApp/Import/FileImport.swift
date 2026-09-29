import Foundation
import TandemCore
import TandemMedia

/// Where a file dropped from Finder goes in the project folder.
struct FileImportPlan: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Already in the project folder (or copied there before): used as is.
        case inPlace
        /// Copied in. On the same disk that's an APFS clone: instant, and
        /// no extra space.
        case copy
        /// On another disk, so linked from `linked-media/` rather than
        /// copied. The scanner follows links, as it does for imported
        /// Filmora projects.
        case link
    }

    var source: URL
    /// Relative to the project folder.
    var destination: String
    var action: Action
}

/// Files and folders dropped from Finder onto the timeline or the media
/// browser. They end up in the project folder where `refreshMedia` would
/// find them, then join the project in one edit (and, on the timeline,
/// get placed where they were dropped).
enum FileImport {
    /// The media files among dropped files and folders (searched, hidden
    /// files skipped), in the order dropped, each once.
    static func mediaFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let url = url.standardizedFileURL
            guard MediaScanner.mediaKind(forPath: url.path) != nil, !url.lastPathComponent.hasPrefix("."), seen.insert(url.path).inserted else { return }
            result.append(url)
        }
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            guard isFolder.boolValue else {
                add(url)
                continue
            }
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var found: [URL] = []
            while let next = enumerator?.nextObject() as? URL {
                if (try? next.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { found.append(next) }
            }
            found.sorted { $0.path < $1.path }.forEach(add)
        }
        return result
    }

    /// The folder a file joins by kind: video is B-roll, pictures are
    /// graphics, sound goes to `audio/` (the scanner calls short sounds
    /// effects and long ones music).
    static func subfolder(for url: URL) -> String {
        switch MediaScanner.mediaKind(forPath: url.path) {
        case .video?: return "broll"
        case .image?: return "graphics"
        default: return "audio"
        }
    }

    /// Where each file goes. Files already in the folder stay put; others
    /// are copied in, or linked when `sameVolume` says they're on another
    /// disk. A name that's taken by a different file gets a number.
    static func plan(_ files: [URL], folder: ProjectFolder, sameVolume: (URL) -> Bool) -> [FileImportPlan] {
        var taken = Set<String>()
        return files.map { file in
            let file = file.standardizedFileURL
            let relative = folder.path(for: file)
            if !relative.hasPrefix("/"), !MediaScanner.isSkippedPath(relative) {
                return FileImportPlan(source: file, destination: relative, action: .inPlace)
            }
            let action: FileImportPlan.Action = sameVolume(file) ? .copy : .link
            let directory = action == .link ? "linked-media" : subfolder(for: file)
            let base = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            var number = 1
            while true {
                let name = number == 1 ? file.lastPathComponent : "\(base) \(number).\(ext)"
                let destination = "\(directory)/\(name)"
                let target = folder.url(forPath: destination)
                if !taken.contains(destination) {
                    if !FileManager.default.fileExists(atPath: target.path) {
                        taken.insert(destination)
                        return FileImportPlan(source: file, destination: destination, action: action)
                    }
                    if sameFile(file, target) {
                        taken.insert(destination)
                        return FileImportPlan(source: file, destination: destination, action: .inPlace)
                    }
                }
                number += 1
            }
        }
    }

    /// True when two files are the same file, or hold the same bytes.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.resolvingSymlinksInPath() == b.resolvingSymlinksInPath() { return true }
        let manager = FileManager.default
        guard let sizeA = (try? manager.attributesOfItem(atPath: a.path))?[.size] as? Int64,
              let sizeB = (try? manager.attributesOfItem(atPath: b.path))?[.size] as? Int64, sizeA == sizeB else { return false }
        return (try? Fingerprint.compute(for: a).contentID) == (try? Fingerprint.compute(for: b).contentID)
    }

    /// Copies and links the files into the folder. Returns each file where
    /// it now is, in plan order.
    static func perform(_ plan: [FileImportPlan], folder: ProjectFolder) throws -> [URL] {
        let manager = FileManager.default
        return try plan.map { item in
            let target = folder.url(forPath: item.destination)
            switch item.action {
            case .inPlace:
                break
            case .copy:
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A clone on APFS when source and folder share a disk.
                try manager.copyItem(at: item.source, to: target)
            case .link:
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.createSymbolicLink(at: target, withDestinationURL: item.source)
            }
            return target
        }
    }

    /// True when a file is on the same disk as the folder.
    static func onSameVolume(_ url: URL, as folder: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let a = (try? url.resourceValues(forKeys: [key]))?.volumeIdentifier as? NSObject,
              let b = (try? folder.resourceValues(forKeys: [key]))?.volumeIdentifier as? NSObject else { return true }
        return a.isEqual(b)
    }

    /// The edit for probed files: new media added (a file the project
    /// already has keeps its media, matched by ID or by where it is in the
    /// folder), and with `at`, each placed after the one before, stills for
    /// 5 s. Dropping one file on a track uses that track. With `newTrack`
    /// (a drop above or below the tracks) the files that fit go on a track
    /// made for them, and the rest are placed as usual. Nil when there's
    /// nothing to do.
    static func batch(_ items: [MediaItem], into project: Project, folder: ProjectFolder? = nil, at time: Time?, trackID: String?, newTrack: (kind: TrackKind, id: String)? = nil) -> EditBatch? {
        var project = project
        var commands: [EditCommand] = []
        var ids: [String] = []
        // Paths compared as the folder resolves them, the way the media
        // scan does, and in one Unicode form (Finder names can differ).
        func key(_ item: MediaItem) -> String {
            let path = folder.map { $0.path(for: $0.url(for: item)) } ?? item.path
            return path.precomposedStringWithCanonicalMapping
        }
        for item in items {
            if let existing = project.media.first(where: { $0.id == item.id || key($0) == key(item) }) {
                if !ids.contains(existing.id) { ids.append(existing.id) }
                continue
            }
            project.media.append(item)
            commands.append(.addMedia(item: item))
            ids.append(item.id)
        }
        guard let time else {
            guard !commands.isEmpty else { return nil }
            return EditBatch(label: commands.count == 1 ? "Add \(name(of: ids[0], in: project)) to the media" : "Add \(commands.count) files to the media", commands: commands)
        }
        var start = max(.zero, time)
        var madeTrack = false
        for id in ids {
            guard let placed = TimelineEdits.placeMedia(project, mediaIDs: [id], at: start, trackID: ids.count == 1 ? trackID : nil, insert: false) else { continue }
            if let newTrack, let item = project.media(id), fits(item, on: newTrack.kind) {
                if !madeTrack { commands.append(.addTrack(kind: newTrack.kind, id: newTrack.id)) }
                madeTrack = true
                commands.append(.placeMedia(
                    mediaIDs: [id], at: start, mode: .overwrite,
                    videoTrackID: newTrack.kind == .video ? newTrack.id : nil, audioTrackID: newTrack.kind == .audio ? newTrack.id : nil
                ))
            } else {
                commands += placed.commands
            }
            start = start + (project.media(id)?.duration ?? Time(seconds: 5))
        }
        guard !commands.isEmpty else { return nil }
        let label = ids.count == 1 ? "Add \(name(of: ids[0], in: project))" : "Add \(ids.count) files"
        guard madeTrack, let newTrack else { return EditBatch(label: label, commands: commands) }
        return EditBatch(label: label + (newTrack.kind == .video ? " on a new video track" : " on a new audio track"), commands: commands)
    }

    /// Picture goes on a video track and sound on an audio track.
    private static func fits(_ item: MediaItem, on kind: TrackKind) -> Bool {
        kind == .video ? item.hasVideo || item.kind == .image : item.hasAudio
    }

    /// Commits probed files to the project as it is at that moment, not
    /// as the window last saw it: the folder watcher's media scan can add
    /// the same files while they're copied and probed, and those are
    /// reused rather than added twice. The edit carries the revision it was
    /// worked out against, and is worked out again if another commit lands
    /// first. `beforeApply` is for tests to land one. Nil when there's
    /// nothing left to do.
    static func commit(_ items: [MediaItem], to coordinator: ProjectCoordinator, folder: ProjectFolder, at time: Time?, trackID: String?, newTrack: TrackKind? = nil, attempts: Int = 20, beforeApply: (() -> Void)? = nil) throws -> (batch: EditBatch, result: ProjectCoordinator.CommitResult)? {
        var attempt = 0
        // One ID for every attempt, so a retry doesn't make another track.
        let made = newTrack.map { (kind: $0, id: IDs.make("trk")) }
        while true {
            attempt += 1
            let (current, revision) = coordinator.snapshot()
            guard var batch = batch(items, into: current, folder: folder, at: time, trackID: trackID, newTrack: made) else { return nil }
            batch.expectedRevision = revision
            beforeApply?()
            do {
                return (batch, try coordinator.apply(batch))
            } catch EditError.staleRevision where attempt < attempts {
                continue
            }
        }
    }

    private static func name(of id: String, in project: Project) -> String {
        project.media(id).map { MediaCatalog.displayName(forPath: $0.path) } ?? "file"
    }
}
