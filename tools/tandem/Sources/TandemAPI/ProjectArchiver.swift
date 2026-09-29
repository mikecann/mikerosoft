import Darwin
import Foundation
import TandemAssets
import TandemCore
import TandemMedia

/// Makes a project folder standalone, so it opens on another Mac with
/// nothing missing.
///
/// A project's media paths are mostly relative to its folder, but some
/// point outside it (an import's absolute paths, a LUT in Downloads, a
/// sound from another video's folder), and titles name fonts that may only
/// be installed on this Mac. Archiving finds all of them in the open
/// project and in the other project files beside it (versions):
///
/// - media files and LUTs whose files are outside the folder (following
///   links, so a link to a file elsewhere counts as outside) are copied to
///   `media/<the folder they were in>/<name>` and `assets/lut/<name>`;
/// - a record-it take's `<base>.take.json` goes beside its take;
/// - fonts titles use that don't come with macOS are copied into
///   `assets/font/`, which the app registers when it opens a project;
/// - references to files inside the folder written as absolute paths are
///   made relative.
///
/// Consolidating copies them into the project's own folder and points the
/// project at the copies with one edit through the coordinator (one undo
/// step, journaled, autosaved). Archiving to a destination copies the whole
/// folder there as well, less what Tandem rebuilds on its own, and writes
/// the copies of the project files with the new paths; the original folder
/// is left as it was.
///
/// Every copy is an APFS clone when it can be, is checked against the
/// original (size, and SHA-256 when it wasn't a clone), keeps its
/// modification date (fingerprints and so the analysis cache depend on it)
/// and waits under a hidden name until it's whole. A file already at the
/// destination with the same content is used as it is; a different file
/// with the same name is never replaced, the copy goes beside it. So a run
/// that's cut short (Cancel, a crash, a share going away) changes nothing
/// in the project, and running it again picks up where it stopped.
/// `archive.json` in the standalone folder records where every file came
/// from.
public final class ProjectArchiver: @unchecked Sendable {
    /// Applies an edit batch and returns the new revision. The service
    /// passes its own `apply`, so headless undo history and idempotency
    /// work as for any edit.
    public typealias ApplyEdit = (EditBatch) throws -> Int

    public let session: ProjectSession
    public let options: ArchiveOptions
    public let control: ArchiveControl
    private let onProgress: ((ArchiveProgress) -> Void)?
    private let applyEdit: ApplyEdit

    public init(session: ProjectSession, options: ArchiveOptions, control: ArchiveControl = ArchiveControl(), progress: ((ArchiveProgress) -> Void)? = nil, applyEdit: ApplyEdit? = nil) {
        self.session = session
        self.options = options
        self.control = control
        self.onProgress = progress
        self.applyEdit = applyEdit ?? { batch in try session.coordinator.apply(batch).revision }
    }

    /// Runs `work` on a GCD thread, never one of Swift's cooperative
    /// threads, since copying blocks for as long as it takes.
    public static func onBackgroundThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Running

    /// Plans, and unless it's a dry run, copies and rewrites. Blocks until
    /// it's done; call it off the main thread.
    public func run() throws -> ArchiveResult {
        try control.check()
        let projectURL = session.fileURL
        let source = ProjectFolder(projectFile: projectURL)
        guard let sourceReal = Self.realPath(source.root) else {
            throw ServiceError(.notFound, "The project's folder isn't at \(source.root.path) any more.")
        }
        if !options.dryRun {
            do {
                try session.save()
            } catch {
                throw ServiceError(.unavailable, "The project couldn't be saved first, so nothing was archived: \(ServiceError.wrap(error).message)")
            }
        }
        report("Looking for the files the project uses", 0, 0, 0)
        let (project, revision) = session.coordinator.snapshot()

        let mode: ArchiveMode = options.destination == nil ? .consolidate : .archive
        let root = try options.destination.map { try archiveFolder(in: $0, source: source, sourceReal: sourceReal, projectID: project.id) } ?? source.root
        let plan = Plan(mode: mode, source: source, sourceReal: sourceReal, root: root)
        var warnings: [String] = []
        let others = otherProjects(in: source, besides: projectURL, warnings: &warnings)
        plan.projects = [ProjectEntry(url: projectURL, project: project, revision: revision, isMain: true)] + others
        plan.warnings = warnings
        plan.manifest = try ArchiveManifest.load(from: root)
        if mode == .archive {
            plan.sourceManifest = try ArchiveManifest.load(from: source.root)
            // An earlier archive's copy open in Tandem would save over the
            // one this writes.
            for entry in plan.projects {
                let copy = root.appendingPathComponent(entry.url.lastPathComponent)
                // Held by this process counts too: the app may have the
                // copy open in another window.
                if LockHandle.isHeld(ProjectSession.lockURL(for: copy)) {
                    throw ServiceError(.locked, "The archive's copy of \(entry.url.lastPathComponent) is open in Tandem. Close it there and archive again.")
                }
            }
        }

        if mode == .archive { walkFolder(plan) }
        addReferences(plan)
        addFonts(plan)
        plan.leftOut = plan.leftOut.filter { part in
            // A link whose file was brought in anyway isn't worth a line.
            guard let target = plan.linkTargets[part.path] else { return true }
            return plan.jobsBySource[target] == nil
        }
        plan.folderJobs.sort { $0.preferred < $1.preferred }
        try control.check()

        if options.dryRun { return result(plan, dryRun: true, revision: nil, others: [], manifest: nil) }
        try checkSpace(plan)
        return try execute(plan)
    }

    private func execute(_ plan: Plan) throws -> ArchiveResult {
        let started = Date()
        var manifest = plan.manifest ?? ArchiveManifest(project: .init(id: "", name: "", file: ""))
        let main = plan.projects[0]
        manifest.project = .init(id: main.project.id, name: main.project.name, file: main.url.lastPathComponent)
        var run = ArchiveManifest.Run(
            date: started, mode: plan.mode, from: plan.source.root.path, to: plan.root.path,
            machine: ProcessInfo.processInfo.hostName, user: NSUserName(), tandem: TandemAPI.version,
            complete: false, collected: plan.jobs.count, copiedFiles: 0, copiedBytes: 0, reusedFiles: 0,
            missing: plan.missing.count, withCache: options.withCache
        )
        if plan.mode == .archive {
            // Written first, so a run cut short leaves a folder the next
            // run knows is this project's archive and carries on with.
            try FileManager.default.createDirectory(at: plan.root, withIntermediateDirectories: true)
            manifest.runs.append(run)
            manifest.updated = started
            try manifest.write(to: plan.root)
        }

        let jobs = plan.folderJobs + plan.jobs
        let meter = Meter(total: jobs.reduce(Int64(0)) { $0 + $1.units }, files: jobs.count, report: onProgress)
        var placed: [String: String] = [:]
        for job in jobs {
            try place(job, plan: plan, meter: meter, placed: &placed)
        }
        if plan.mode == .consolidate {
            try moveStagedIntoPlace(plan)
        }
        meter.say("Updating the project")

        // Where each reference points now. A file of the folder's own that
        // went beside an older, different copy in the archive takes its
        // references with it.
        var map: [String: String] = [:]
        let folderCopies = Dictionary(plan.folderJobs.map { ($0.preferred.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for (stored, place) in plan.inside {
            if let job = folderCopies[place.relative.lowercased()], job.destination.lowercased() != place.relative.lowercased() {
                map[stored] = job.destination
            } else if !place.clean {
                map[stored] = place.relative
            }
        }
        for (stored, job) in plan.external { map[stored] = job.destination }

        let copied = jobs.filter { $0.outcome == .copied || $0.outcome == .cloned }
        run.copiedFiles = copied.count
        run.copiedBytes = copied.reduce(Int64(0)) { $0 + $1.bytes }
        run.reusedFiles = jobs.filter { $0.outcome == .reused }.count
        run.complete = true
        let now = Date()
        var entries: [ArchiveManifest.Entry] = []
        if let carried = plan.sourceManifest?.files {
            manifest.record(carried)
        }
        for job in jobs where !job.isCache {
            let entry = ArchiveManifest.Entry(path: job.destination, original: job.original, kind: job.kind, bytes: job.bytes, sha256: job.sha256, modified: job.modified, archived: now)
            // A file the project folder had already brought in keeps the
            // record of where it first came from.
            if job.kind == .folder, let earlier = plan.sourceManifest?.entry(for: job.destination), earlier.sha256 == job.sha256 { continue }
            entries.append(entry)
        }
        manifest.record(entries)
        manifest.missing = plan.missing
        manifest.updated = now
        if plan.mode == .archive, !manifest.runs.isEmpty, manifest.runs[manifest.runs.count - 1].date == started {
            manifest.runs[manifest.runs.count - 1] = run
        } else {
            manifest.runs.append(run)
        }
        // Before the project points at the copies: a run stopped between
        // the two still has the record, and the next one finds the copies.
        try manifest.write(to: plan.root)

        var revision: Int?
        var others: [OtherProjectFile] = []
        switch plan.mode {
        case .consolidate:
            revision = try rewriteOpenProject(map: map, plan: plan)
            try session.save()
            others = rewriteOtherProjects(map: map, plan: plan)
        case .archive:
            for entry in plan.projects {
                let (rewritten, count) = try Self.rewritten(entry.project, map: map)
                let target = plan.root.appendingPathComponent(entry.url.lastPathComponent)
                // A journal or undo history an earlier archive left there
                // belongs to the file this replaces.
                ProjectFile.forgetHistory(of: target)
                try ProjectFile.save(rewritten, revision: entry.revision, to: target)
                if !entry.isMain { others.append(OtherProjectFile(file: entry.url.lastPathComponent, rewritten: count, note: nil)) }
            }
        }
        removeLeftoverCopies(plan)
        meter.say("Done")
        return result(plan, dryRun: false, revision: revision, others: others, manifest: ArchiveManifest.url(in: plan.root).path)
    }

    // MARK: - The destination

    /// `<parent>/<project folder name>`, or the next free `<name> 2` when
    /// that's taken by something else. An earlier (or unfinished) archive
    /// of this project is used again.
    private func archiveFolder(in parent: URL, source: ProjectFolder, sourceReal: String, projectID: String) throws -> URL {
        let parent = parent.standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ServiceError(.notFound, "There's no folder at \(parent.path) to archive into. If it's on another Mac, check the share is mounted.")
        }
        if let parentReal = Self.realPath(parent), parentReal == sourceReal || Self.isInside(parentReal, sourceReal) {
            throw ServiceError(.invalid, "The archive can't go inside the project's own folder. Pick a folder outside \(source.root.path).")
        }
        let name = source.root.lastPathComponent
        for n in 1...999 {
            let candidate = parent.appendingPathComponent(n == 1 ? name : "\(name) \(n)", isDirectory: true)
            guard FileCopier.anythingAt(candidate) else { return candidate }
            // Archiving into the folder the project is in makes a copy
            // beside it.
            if Self.realPath(candidate) == sourceReal { continue }
            if Self.isArchive(candidate, of: projectID) || Self.isEmptyFolder(candidate) { return candidate }
        }
        throw ServiceError(.invalid, "Couldn't find a free name for the archive in \(parent.path).")
    }

    /// True when `folder` holds an archive (or part of one) of `projectID`.
    static func isArchive(_ folder: URL, of projectID: String) -> Bool {
        if let manifest = try? ArchiveManifest.load(from: folder), manifest.project.id == projectID { return true }
        struct Header: Decodable {
            struct Inner: Decodable { var id: String }
            var project: Inner
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.contains { file in
            guard file.pathExtension == ProjectFile.fileExtension, let data = try? Data(contentsOf: file) else { return false }
            return (try? JSONDecoder().decode(Header.self, from: data))?.project.id == projectID
        }
    }

    static func isEmptyFolder(_ folder: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        return entries.allSatisfy { $0 == ".DS_Store" }
    }

    /// The other `.tandem` files in the folder, with any edits a crash left
    /// in their journals.
    private func otherProjects(in folder: ProjectFolder, besides main: URL, warnings: inout [String]) -> [ProjectEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder.root, includingPropertiesForKeys: nil)) ?? []
        var entries: [ProjectEntry] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension == ProjectFile.fileExtension, !url.lastPathComponent.hasPrefix("."),
                  url.lastPathComponent != main.lastPathComponent else { continue }
            do {
                let (project, revision) = try ProjectFile.load(from: url)
                let journal = ProjectJournal(url: ProjectFile.journalURL(for: url))
                let latest = journal.recover(project: project, revision: revision) ?? (project, revision)
                entries.append(ProjectEntry(url: url, project: latest.project, revision: latest.revision, isMain: false))
            } catch {
                warnings.append("\(url.lastPathComponent) couldn't be read, so it's left as it is: \(ServiceError.wrap(error).message)")
            }
        }
        return entries
    }

    // MARK: - Planning

    /// One project file the run makes standalone.
    struct ProjectEntry {
        let url: URL
        var project: Project
        var revision: Int
        let isMain: Bool
    }

    /// One file to copy.
    final class Job {
        let kind: ArchivedKind
        /// The file to read (links followed).
        let source: URL
        /// Where the bytes were, for the manifest.
        let original: String
        /// Where it goes, relative to the standalone folder.
        let preferred: String
        /// Where it went: `preferred`, or a name beside it.
        var destination: String
        let bytes: Int64
        let modified: Date
        /// Analysis results: checked by size only, and not listed in the
        /// manifest.
        let isCache: Bool
        var usedBy: [String] = []
        var outcome: ArchivedFile.Outcome = .planned
        var sha256: String?
        /// Consolidating: the checked copy, still under its hidden name.
        var staged: URL?

        init(kind: ArchivedKind, source: URL, original: String, preferred: String, bytes: Int64, modified: Date, isCache: Bool = false) {
            self.kind = kind
            self.source = source
            self.original = original
            self.preferred = preferred
            self.destination = preferred
            self.bytes = bytes
            self.modified = modified
            self.isCache = isCache
        }

        /// Work for the progress bar: reading the original, copying, and
        /// reading the copy back.
        var units: Int64 { max(bytes, 1) * (isCache ? 1 : 3) }
    }

    /// Everything a run decides before it copies anything.
    final class Plan {
        let mode: ArchiveMode
        let source: ProjectFolder
        let sourceReal: String
        /// The folder that ends up standalone.
        let root: URL
        var projects: [ProjectEntry] = []
        /// Archive mode: the project folder's own files.
        var folderJobs: [Job] = []
        /// Files brought in from outside.
        var jobs: [Job] = []
        var jobsBySource: [String: Job] = [:]
        /// Destination paths (lower-cased) and the real path of the file
        /// that has each.
        var claims: [String: String] = [:]
        /// Stored path of a reference to an outside file, and its copy.
        var external: [String: Job] = [:]
        /// Stored path of a reference to a file inside the folder, its
        /// relative path, and whether the stored path already is that.
        var inside: [String: (relative: String, clean: Bool)] = [:]
        /// Archive mode: the folder copy's paths, lower-cased.
        var folderPaths = Set<String>()
        /// Links the folder copy left out, and the real paths they point to.
        var linkTargets: [String: String] = [:]
        var missing: [MissingFile] = []
        var fonts: [ArchivedFont] = []
        var leftOut: [LeftOut] = []
        var warnings: [String] = []
        /// The standalone folder's manifest before this run.
        var manifest: ArchiveManifest?
        /// Archive mode: the project folder's own manifest.
        var sourceManifest: ArchiveManifest?

        init(mode: ArchiveMode, source: ProjectFolder, sourceReal: String, root: URL) {
            self.mode = mode
            self.source = source
            self.sourceReal = sourceReal
            self.root = root
        }

        /// A destination for a file: where it wants to go, or the first free
        /// name beside it. A file already there with the same size is taken
        /// to be this one for now; copying checks its content.
        func claim(_ preferred: String, source: String, bytes: Int64) -> String {
            var n = 1
            while true {
                let candidate = FileCopier.alongside(preferred, n)
                let key = candidate.lowercased()
                if let holder = claims[key] {
                    if holder == source { return candidate }
                } else {
                    let url = root.appendingPathComponent(candidate)
                    if !FileCopier.anythingAt(url) || (FileCopier.isPlainFile(url) && FileCopier.fileInfo(url)?.size == bytes) {
                        claims[key] = source
                        return candidate
                    }
                }
                n += 1
            }
        }
    }

    /// A reference to a file in a project: a media item's path or a LUT's.
    struct Reference {
        var kind: ArchivedKind
        var stored: String
        var owner: String
        var clips: Int
    }

    /// Every file a project refers to, in project order.
    static func references(in project: Project) -> [Reference] {
        var clipCounts: [String: Int] = [:]
        for clip in project.allTracks.flatMap(\.clips) {
            if let id = clip.mediaID { clipCounts[id, default: 0] += 1 }
        }
        var found: [Reference] = []
        for item in project.media {
            found.append(Reference(kind: .media, stored: item.path, owner: item.id, clips: clipCounts[item.id] ?? 0))
            for effect in item.look {
                if let path = lutPath(effect) { found.append(Reference(kind: .lut, stored: path, owner: "\(item.id) look", clips: clipCounts[item.id] ?? 0)) }
            }
        }
        for track in project.allTracks {
            for clip in track.clips {
                for effect in (clip.video?.effects ?? []) + (clip.audio?.effects ?? []) {
                    if let path = lutPath(effect) { found.append(Reference(kind: .lut, stored: path, owner: clip.id, clips: 1)) }
                }
            }
        }
        return found
    }

    /// The file a LUT effect reads.
    static func lutPath(_ effect: Effect) -> String? {
        guard effect.type == "lut", case .string(let path)? = effect.params["path"], !path.isEmpty else { return nil }
        return path
    }

    private func addReferences(_ plan: Plan) {
        struct Uses {
            var kind: ArchivedKind
            var owners: [String] = []
            var clips = 0
        }
        var order: [String] = []
        var uses: [String: Uses] = [:]
        for entry in plan.projects {
            for reference in Self.references(in: entry.project) {
                if uses[reference.stored] == nil {
                    order.append(reference.stored)
                    uses[reference.stored] = Uses(kind: reference.kind)
                }
                if !uses[reference.stored]!.owners.contains(reference.owner) {
                    uses[reference.stored]!.owners.append(reference.owner)
                    uses[reference.stored]!.clips += reference.clips
                }
            }
        }
        for stored in order {
            guard let use = uses[stored] else { continue }
            let url = plan.source.url(forPath: stored).standardizedFileURL
            switch Self.place(of: stored, in: plan.source, real: plan.sourceReal) {
            case .missing:
                plan.missing.append(MissingFile(kind: use.kind, path: stored, usedBy: use.owners, clips: use.clips))
            case .inside(let relative, let clean):
                if plan.mode == .archive, !plan.folderPaths.contains(relative.lowercased()), let real = Self.realPath(url) {
                    // In a part of the folder the archive leaves out, so
                    // it's brought in like a file from outside.
                    addOutside(plan, stored: stored, referenced: url, real: real, kind: use.kind, usedBy: use.owners)
                } else {
                    plan.inside[stored] = (relative, clean)
                }
            case .outside(let real):
                addOutside(plan, stored: stored, referenced: url, real: real, kind: use.kind, usedBy: use.owners)
            }
        }
    }

    private func addOutside(_ plan: Plan, stored: String, referenced url: URL, real: String, kind: ArchivedKind, usedBy: [String]) {
        if let job = plan.jobsBySource[real] {
            job.usedBy += usedBy.filter { !job.usedBy.contains($0) }
            plan.external[stored] = job
            return
        }
        guard let info = FileCopier.fileInfo(URL(fileURLWithPath: real)) else { return }
        let preferred = destination(for: url, real: real, kind: kind)
        let job = Job(kind: kind, source: URL(fileURLWithPath: real), original: real, preferred: preferred, bytes: info.size, modified: info.modified)
        job.destination = plan.claim(preferred, source: real, bytes: info.size)
        job.usedBy = usedBy
        plan.jobs.append(job)
        plan.jobsBySource[real] = job
        plan.external[stored] = job
        // A record-it take lines up its files with the sidecar beside it.
        guard kind == .media, let base = Self.takeBase(url.lastPathComponent) else { return }
        let sidecar = url.deletingLastPathComponent().appendingPathComponent(TakeSidecar.fileName(forBase: base))
        guard let sidecarReal = Self.realPath(sidecar), plan.jobsBySource[sidecarReal] == nil,
              let sidecarInfo = FileCopier.fileInfo(URL(fileURLWithPath: sidecarReal)) else { return }
        let sidecarPreferred = ((job.preferred as NSString).deletingLastPathComponent as NSString).appendingPathComponent(sidecar.lastPathComponent)
        let sidecarJob = Job(kind: .sidecar, source: URL(fileURLWithPath: sidecarReal), original: sidecarReal, preferred: sidecarPreferred, bytes: sidecarInfo.size, modified: sidecarInfo.modified)
        sidecarJob.destination = plan.claim(sidecarPreferred, source: sidecarReal, bytes: sidecarInfo.size)
        sidecarJob.usedBy = usedBy
        plan.jobs.append(sidecarJob)
        plan.jobsBySource[sidecarReal] = sidecarJob
    }

    private func addFonts(_ plan: Plan) {
        var users: [String: [String]] = [:]
        for entry in plan.projects {
            for (family, clips) in ArchiveFonts.families(in: entry.project) { users[family, default: []] += clips }
        }
        let projectFonts = plan.source.assetsFolder.appendingPathComponent("font", isDirectory: true)
        for family in users.keys.sorted() {
            let clips = users[family] ?? []
            if ArchiveFonts.isSystemName(family) {
                plan.fonts.append(ArchivedFont(family: family, status: .system, files: []))
                continue
            }
            if !ArchiveFonts.files(of: family, in: projectFonts).isEmpty {
                plan.fonts.append(ArchivedFont(family: family, status: .inProject, files: []))
                continue
            }
            var sources: [String] = []
            switch options.fonts.locate(family) {
            case .system:
                plan.fonts.append(ArchivedFont(family: family, status: .system, files: []))
                continue
            case .notFound:
                break
            case .files(let urls):
                for url in urls {
                    guard let real = Self.realPath(url), let info = FileCopier.fileInfo(URL(fileURLWithPath: real)) else { continue }
                    sources.append(real)
                    if let job = plan.jobsBySource[real] {
                        if !job.usedBy.contains(family) { job.usedBy.append(family) }
                        continue
                    }
                    let preferred = "assets/font/\(url.lastPathComponent)"
                    let job = Job(kind: .font, source: URL(fileURLWithPath: real), original: real, preferred: preferred, bytes: info.size, modified: info.modified)
                    job.destination = plan.claim(preferred, source: real, bytes: info.size)
                    job.usedBy = [family]
                    plan.jobs.append(job)
                    plan.jobsBySource[real] = job
                }
            }
            if sources.isEmpty {
                plan.fonts.append(ArchivedFont(family: family, status: .missing, files: []))
                plan.missing.append(MissingFile(kind: .font, path: family, usedBy: Array(clips.prefix(5)), clips: clips.count))
            } else {
                plan.fonts.append(ArchivedFont(family: family, status: .collected, files: sources))
            }
        }
    }

    // MARK: - The folder copy (archive mode)

    /// Analysis the archive leaves out unless asked: big, and Tandem makes
    /// it again for what the edit uses. Transcripts, waveforms and loudness
    /// always go; transcripts especially are slow to make again. So do the
    /// converted copies of stickers macOS can't decode: they're small, and
    /// making them again needs ffmpeg, which the Mac opening it may not have.
    static let rebuildableCache = Set([AnalysisKind.proxy, .matte, .thumbnails, .isolatedVoice].map(\.rawValue))

    private func walkFolder(_ plan: Plan) {
        // Written by the run itself, with the new paths.
        var written: Set<String> = [ArchiveManifest.fileName]
        for entry in plan.projects {
            let name = entry.url.lastPathComponent
            let stem = entry.url.deletingPathExtension().lastPathComponent
            written.formUnion([name, ".tandem/\(stem).journal.jsonl", ".tandem/\(stem).undo.json"])
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var folders: [(URL, String)] = [(plan.source.root, "")]
        while let (folder, prefix) = folders.popLast() {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
            } catch {
                plan.warnings.append("Couldn't read \(prefix.isEmpty ? "the project folder" : prefix), so it isn't in the archive: \(error.localizedDescription)")
                continue
            }
            for url in entries {
                let name = url.lastPathComponent
                let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true {
                    addLink(url, relative: relative, plan: plan)
                    continue
                }
                if values?.isDirectory == true {
                    if Self.isScratch(relative) { continue }
                    if let why = Self.whyLeftOut(folder: relative, name: name, withCache: options.withCache) {
                        let (files, bytes) = Self.size(of: url)
                        plan.leftOut.append(LeftOut(path: relative, why: why, files: files, bytes: bytes))
                        continue
                    }
                    folders.append((url, relative))
                    continue
                }
                guard values?.isRegularFile == true, !written.contains(relative), !Self.isScratch(relative), name != ".DS_Store",
                      !(name.hasSuffix(".lock") && (prefix as NSString).lastPathComponent == ".tandem"),
                      let info = FileCopier.fileInfo(url) else { continue }
                let real = Self.realPath(url) ?? url.path
                let job = Job(kind: .folder, source: URL(fileURLWithPath: real), original: url.path, preferred: relative, bytes: info.size, modified: info.modified, isCache: Self.isCache(relative))
                job.destination = plan.claim(relative, source: real, bytes: info.size)
                plan.folderJobs.append(job)
                plan.folderPaths.insert(relative.lowercased())
            }
        }
    }

    /// A link in the project folder: a link to another file in the folder
    /// is copied as that file; links elsewhere are left out (a file the
    /// project uses through one is brought in with the outside files).
    private func addLink(_ url: URL, relative: String, plan: Plan) {
        guard let real = Self.realPath(url) else {
            plan.leftOut.append(LeftOut(path: relative, why: "a link to something that isn't there", files: 0, bytes: 0))
            return
        }
        guard let info = FileCopier.fileInfo(URL(fileURLWithPath: real)) else {
            plan.leftOut.append(LeftOut(path: relative, why: "a link to a folder (\(ByteText.home(real))); links aren't copied, but files the project uses through it are brought in", files: 0, bytes: 0))
            plan.linkTargets[relative] = real
            return
        }
        guard Self.isInside(real, plan.sourceReal) else {
            plan.leftOut.append(LeftOut(path: relative, why: "a link to a file outside the project folder (\(ByteText.home(real)))", files: 1, bytes: info.size))
            plan.linkTargets[relative] = real
            return
        }
        let job = Job(kind: .folder, source: URL(fileURLWithPath: real), original: url.path, preferred: relative, bytes: info.size, modified: info.modified, isCache: Self.isCache(relative))
        job.destination = plan.claim(relative, source: real, bytes: info.size)
        plan.folderJobs.append(job)
        plan.folderPaths.insert(relative.lowercased())
    }

    /// Why a folder isn't copied, or nil when it is.
    static func whyLeftOut(folder relative: String, name: String, withCache: Bool) -> String? {
        if name == "node_modules" { return "npm packages, which `npm install` puts back" }
        let parts = relative.split(separator: "/").map(String.init)
        if !withCache, parts.count >= 3, parts[parts.count - 3] == ".tandem", parts[parts.count - 2] == "cache", rebuildableCache.contains(name) {
            let what: String
            switch AnalysisKind(rawValue: name) {
            case .proxy: what = "proxies"
            case .matte: what = "cutout mattes"
            case .thumbnails: what = "thumbnails"
            case .isolatedVoice: what = "isolated voice"
            default: what = name
            }
            return "\(what), which Tandem makes again for what the edit uses when the archive is opened (--with-cache keeps them)"
        }
        return nil
    }

    /// Temporary files: an analysis still being written (or thrown away)
    /// in the cache, or a copy an archive was part way through.
    static func isScratch(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return true }
        if FileCopier.isTemporary(name) { return true }
        if let cache = cacheIndex(parts) {
            return parts[(cache + 1)...].contains { $0.hasPrefix(".") }
        }
        return false
    }

    static func isCache(_ relative: String) -> Bool {
        cacheIndex(relative.split(separator: "/").map(String.init)) != nil
    }

    /// Where `.tandem/cache` is in a path's parts, if it's in the cache.
    private static func cacheIndex(_ parts: [String]) -> Int? {
        guard parts.count >= 2 else { return nil }
        for index in 1..<parts.count where parts[index] == "cache" && parts[index - 1] == ".tandem" {
            return index
        }
        return nil
    }

    /// Files and bytes under a folder.
    static func size(of folder: URL) -> (files: Int, bytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    // MARK: - Copying

    /// Puts one file in place: uses a file already there with the same
    /// content, goes beside a different one, or copies it under a hidden
    /// name, checks the copy, and (archiving elsewhere) moves it into place.
    private func place(_ job: Job, plan: Plan, meter: Meter, placed: inout [String: String]) throws {
        try control.check()
        let start = meter.done
        let display = job.kind == .folder ? job.preferred : (job.original as NSString).lastPathComponent
        var sha: String?
        if !job.isCache {
            meter.say("Reading \(display)")
            sha = try FileCopier.sha256(of: job.source, control: control) { meter.set(start + $0) }
        }
        var n = 1
        while true {
            try control.check()
            let candidate = FileCopier.alongside(job.preferred, n)
            let key = candidate.lowercased()
            if let holder = placed[key] {
                // Placed earlier in this run: the same content is shared.
                if let sha, holder == sha {
                    finish(job, at: candidate, outcome: .reused, sha: sha, meter: meter, start: start)
                    return
                }
                n += 1
                continue
            }
            let target = plan.root.appendingPathComponent(candidate)
            if FileCopier.anythingAt(target) {
                if try sameContent(target, relative: candidate, job: job, sha: sha, plan: plan) {
                    placed[key] = sha ?? ""
                    finish(job, at: candidate, outcome: .reused, sha: sha, meter: meter, start: start)
                    return
                }
                n += 1
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = FileCopier.temporaryURL(for: target)
            var method = FileCopier.Method.copied
            var ready = false
            if FileCopier.anythingAt(temporary) {
                // Left by a run that was cut short: kept when it's a whole
                // copy of this file.
                if let sha, FileCopier.fileInfo(temporary)?.size == job.bytes, try FileCopier.sha256(of: temporary, control: control) == sha {
                    ready = true
                } else {
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
            if !ready {
                meter.say("Copying \(display)")
                let copyStart = start + (job.isCache ? 0 : job.bytes)
                method = try FileCopier.copy(job.source, to: temporary, clone: options.clone, control: control) { meter.set(copyStart + $0) }
                guard FileCopier.fileInfo(temporary)?.size == job.bytes else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw ServiceError(.internalError, "The copy of \(job.source.path) came out a different size, so it was thrown away and the archive stopped. Nothing in the project changed; try again.")
                }
                if method == .copied, let sha {
                    meter.say("Checking \(display)")
                    let check = try FileCopier.sha256(of: temporary, control: control) { meter.set(start + 2 * job.bytes + $0) }
                    guard check == sha else {
                        try? FileManager.default.removeItem(at: temporary)
                        throw ServiceError(.internalError, "The copy of \(job.source.path) didn't match the original (its SHA-256 differs), so it was thrown away and the archive stopped. Nothing in the project changed; try again.")
                    }
                }
                FileCopier.keepDate(job.modified, on: temporary)
            }
            if plan.mode == .archive {
                guard try FileCopier.moveIntoPlace(temporary, target) else {
                    // Something arrived there meanwhile: look again.
                    try? FileManager.default.removeItem(at: temporary)
                    continue
                }
            } else {
                // Consolidating: the copies stay hidden until they're all
                // done, so the folder watcher never adds one as new media
                // before the project points at it.
                job.staged = temporary
            }
            placed[key] = sha ?? ""
            finish(job, at: candidate, outcome: method == .cloned ? .cloned : .copied, sha: sha, meter: meter, start: start)
            return
        }
    }

    private func finish(_ job: Job, at destination: String, outcome: ArchivedFile.Outcome, sha: String?, meter: Meter, start: Int64) {
        job.destination = destination
        job.outcome = outcome
        job.sha256 = sha
        meter.set(start + job.units)
        meter.fileDone()
    }

    /// True when the regular file at `url` has the content `job` copies. A
    /// file the manifest recorded with this checksum, and whose size and
    /// date haven't changed since, isn't read again.
    private func sameContent(_ url: URL, relative: String, job: Job, sha: String?, plan: Plan) throws -> Bool {
        guard FileCopier.isPlainFile(url), let info = FileCopier.fileInfo(url), info.size == job.bytes else { return false }
        guard let sha else { return true }
        if let entry = plan.manifest?.entry(for: relative), entry.sha256 == sha, entry.bytes == info.size,
           let modified = entry.modified, FileCopier.milliseconds(modified) == FileCopier.milliseconds(info.modified) {
            return true
        }
        return try FileCopier.sha256(of: url, control: control) == sha
    }

    /// Consolidating: moves the checked copies into place, all at once.
    private func moveStagedIntoPlace(_ plan: Plan) throws {
        for job in plan.jobs {
            guard let temporary = job.staged else { continue }
            var candidate = job.destination
            var n = 1
            while !(try FileCopier.moveIntoPlace(temporary, plan.root.appendingPathComponent(candidate))) {
                // A file arrived at that name while copying.
                if try sameContent(plan.root.appendingPathComponent(candidate), relative: candidate, job: job, sha: job.sha256, plan: plan) {
                    try? FileManager.default.removeItem(at: temporary)
                    break
                }
                n += 1
                candidate = FileCopier.alongside(job.destination, n)
            }
            job.destination = candidate
            job.staged = nil
        }
    }

    /// Removes hidden copies an earlier run left in the folders this one
    /// wrote to.
    private func removeLeftoverCopies(_ plan: Plan) {
        let folders = Set((plan.folderJobs + plan.jobs).map { plan.root.appendingPathComponent($0.destination).deletingLastPathComponent().path })
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where FileCopier.isTemporary(name) {
                try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
            }
        }
    }

    /// Refuses to start a copy the destination has no room for. Files on
    /// the same volume clone, which takes no room.
    private func checkSpace(_ plan: Plan) throws {
        var existing = plan.root
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing = existing.deletingLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeNameKey]
        guard let volume = try? existing.resourceValues(forKeys: keys) else { return }
        let available = volume.volumeAvailableCapacityForImportantUsage ?? volume.volumeAvailableCapacity.map(Int64.init)
        guard let available, available > 0 else { return }
        var needed: Int64 = 0
        for job in plan.folderJobs + plan.jobs {
            let sourceVolume = try? job.source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
            if let sourceVolume, let target = volume.volumeIdentifier, sourceVolume.isEqual(target) { continue }
            needed += job.bytes
        }
        guard needed > available else { return }
        throw ServiceError(.unavailable, "There isn't room: the archive needs \(ByteText.size(needed)) on \(volume.volumeName ?? existing.path) and \(ByteText.size(available)) is free. Nothing was copied.")
    }

    // MARK: - Pointing the project at the copies

    /// The edit that points every reference in `map` at its new path,
    /// worked out against `project` as it is, and how many references it
    /// changes. `added` are media IDs that appeared while the run copied: a
    /// folder scan that saw a copy land may have added it as new media,
    /// and a copy nothing plays is removed again.
    static func rewriteCommands(_ project: Project, map: [String: String], added: Set<String> = []) -> (commands: [EditCommand], count: Int) {
        guard !map.isEmpty else { return ([], 0) }
        var commands: [EditCommand] = []
        var count = 0
        var newPaths = Set<String>()
        var moved = Set<String>()
        for item in project.media {
            var patch: [String: JSONValue] = [:]
            if let path = map[item.path], path != item.path {
                patch["path"] = .string(path)
                newPaths.insert(path)
                moved.insert(item.id)
                count += 1
            }
            var look = item.look
            for index in look.indices {
                guard let old = lutPath(look[index]), let path = map[old], path != old else { continue }
                look[index].params["path"] = .string(path)
                count += 1
            }
            if look != item.look, let value = try? JSONValue.from(look) { patch["look"] = value }
            if !patch.isEmpty { commands.append(.updateMedia(mediaID: item.id, patch: .object(patch))) }
        }
        for track in project.allTracks {
            var edits: [EditCommand] = []
            for clip in track.clips {
                for effect in (clip.video?.effects ?? []) + (clip.audio?.effects ?? []) {
                    guard let old = lutPath(effect), let path = map[old], path != old else { continue }
                    edits.append(.updateEffect(clipID: clip.id, effectID: effect.id, patch: .object(["params": .object(["path": .string(path)])])))
                }
            }
            guard !edits.isEmpty else { continue }
            count += edits.count
            // The same LUT from its new place changes nothing on screen, so
            // a locked track is unlocked for it and locked again.
            if track.locked { commands.append(.updateTrack(trackID: track.id, patch: .object(["locked": .bool(false)]))) }
            commands += edits
            if track.locked { commands.append(.updateTrack(trackID: track.id, patch: .object(["locked": .bool(true)]))) }
        }
        let used = Set(project.allTracks.flatMap(\.clips).compactMap(\.mediaID))
        for item in project.media where added.contains(item.id) && newPaths.contains(item.path) && !moved.contains(item.id) && !used.contains(item.id) {
            commands.append(.removeMedia(mediaID: item.id))
        }
        return (commands, count)
    }

    /// A copy of `project` with the references in `map` pointed at their
    /// new paths, made by the same commands an edit would use.
    static func rewritten(_ project: Project, map: [String: String]) throws -> (project: Project, count: Int) {
        let (commands, count) = rewriteCommands(project, map: map)
        var working = project
        var context = EditContext()
        for command in commands {
            try Editing.apply(command, to: &working, context: &context)
        }
        return (working, count)
    }

    /// Points the open project at the copies, as one edit through the
    /// coordinator, worked out again if the project changes meanwhile.
    private func rewriteOpenProject(map: [String: String], plan: Plan) throws -> Int {
        let known = Set(plan.projects[0].project.media.map(\.id))
        let brought = plan.jobs.count
        for attempt in 1...10 {
            let (project, revision) = session.coordinator.snapshot()
            let added = Set(project.media.map(\.id)).subtracting(known)
            let (commands, _) = Self.rewriteCommands(project, map: map, added: added)
            guard !commands.isEmpty else { return revision }
            let label = options.label ?? (brought > 0
                ? "Bring \(brought) file\(brought == 1 ? "" : "s") into the project folder"
                : "Make paths relative to the project folder")
            do {
                return try applyEdit(EditBatch(label: label, author: options.author, commands: commands, expectedRevision: revision))
            } catch where ServiceError.wrap(error).knownCode == .staleRevision && attempt < 10 {
                continue
            }
        }
        return session.coordinator.revision
    }

    /// Consolidating: points the other project files in the folder at the
    /// copies too, each opened for a moment. One that's open somewhere else
    /// is left as it is.
    private func rewriteOtherProjects(map: [String: String], plan: Plan) -> [OtherProjectFile] {
        var results: [OtherProjectFile] = []
        for entry in plan.projects where !entry.isMain {
            let name = entry.url.lastPathComponent
            guard Self.rewriteCommands(entry.project, map: map).count > 0 else { continue }
            do {
                let other = try ProjectSession.open(entry.url, owner: .cli)
                var changed = 0
                defer { other.close() }
                for attempt in 1...10 {
                    let (project, revision) = other.coordinator.snapshot()
                    let (commands, count) = Self.rewriteCommands(project, map: map)
                    guard !commands.isEmpty else { break }
                    do {
                        try other.coordinator.apply(EditBatch(label: "Point at the copies in the project folder", author: options.author, commands: commands, expectedRevision: revision))
                        changed = count
                        break
                    } catch EditError.staleRevision where attempt < 10 {
                        continue
                    }
                }
                try other.save()
                results.append(OtherProjectFile(file: name, rewritten: changed, note: nil))
            } catch let error as EditError {
                if case .locked = error {
                    results.append(OtherProjectFile(file: name, rewritten: 0, note: "open somewhere else, so it still points outside the folder; archive it from there, or once it's closed"))
                } else {
                    results.append(OtherProjectFile(file: name, rewritten: 0, note: "left as it is: \(error.description)"))
                }
            } catch {
                results.append(OtherProjectFile(file: name, rewritten: 0, note: "left as it is: \(ServiceError.wrap(error).message)"))
            }
        }
        return results
    }

    // MARK: - Results

    private func result(_ plan: Plan, dryRun: Bool, revision: Int?, others: [OtherProjectFile], manifest: String?) -> ArchiveResult {
        let all = plan.folderJobs + plan.jobs
        let copied = dryRun ? all : all.filter { $0.outcome == .copied || $0.outcome == .cloned }
        var warnings = plan.warnings
        for job in plan.folderJobs where job.destination != job.preferred && !dryRun {
            warnings.append("\(job.preferred) was already in the archive with different content, so this copy is \(job.destination).")
        }
        let mainName = plan.projects[0].url.lastPathComponent
        return ArchiveResult(
            mode: plan.mode,
            dryRun: dryRun,
            project: session.fileURL.path,
            folder: plan.root.path,
            projectFile: plan.root.appendingPathComponent(mainName).path,
            collected: plan.jobs.map {
                ArchivedFile(kind: $0.kind, original: $0.original, path: $0.destination, bytes: $0.bytes, sha256: $0.sha256, outcome: $0.outcome, usedBy: $0.usedBy)
            },
            madeRelative: plan.inside.values.filter { !$0.clean }.count,
            folderFiles: plan.folderJobs.count,
            folderBytes: plan.folderJobs.reduce(Int64(0)) { $0 + $1.bytes },
            folderParts: Self.parts(of: plan.folderJobs),
            copiedFiles: copied.count,
            copiedBytes: copied.reduce(Int64(0)) { $0 + $1.bytes },
            reusedFiles: all.filter { $0.outcome == .reused }.count,
            missing: plan.missing,
            fonts: plan.fonts,
            leftOut: plan.leftOut,
            otherProjects: others,
            manifest: manifest,
            revision: revision,
            warnings: warnings
        )
    }

    /// The folder copy by top-level file or folder, biggest first.
    static func parts(of jobs: [Job]) -> [FolderPart] {
        var parts: [String: FolderPart] = [:]
        for job in jobs {
            let components = job.preferred.split(separator: "/", maxSplits: 1)
            let top = components.count > 1 ? "\(components[0])/" : job.preferred
            parts[top, default: FolderPart(path: top, files: 0, bytes: 0)].files += 1
            parts[top]?.bytes += job.bytes
        }
        return parts.values.sorted { ($0.bytes, $1.path) > ($1.bytes, $0.path) }
    }

    private func report(_ message: String, _ fraction: Double, _ done: Int, _ total: Int) {
        onProgress?(ArchiveProgress(message: message, fraction: fraction, filesDone: done, filesTotal: total))
    }

    // MARK: - Paths

    enum Place: Equatable {
        case missing
        /// Inside the folder. `clean` when the stored path is already a
        /// plain relative one.
        case inside(relative: String, clean: Bool)
        /// Outside the folder, at this real path.
        case outside(real: String)
    }

    /// Where the file a stored path names really is.
    static func place(of stored: String, in folder: ProjectFolder, real root: String) -> Place {
        let url = folder.url(forPath: stored).standardizedFileURL
        guard let real = realPath(url), FileCopier.fileInfo(URL(fileURLWithPath: real)) != nil else { return .missing }
        guard isInside(real, root) else { return .outside(real: real) }
        if isPlainRelative(stored) { return .inside(relative: stored, clean: true) }
        let spelled = folder.path(for: url)
        return .inside(relative: spelled.hasPrefix("/") ? String(real.dropFirst(root.count + 1)) : spelled, clean: false)
    }

    /// `media/a.mov`, not `/Users/...`, `~/...` or `../`.
    static func isPlainRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Where a file from outside the folder goes: a LUT in `assets/lut/`,
    /// a shared library file in `media/Tandem Library/` where it was in the
    /// library (`media/Tandem Library/Stickers/star.mov`), the library's
    /// converted copy of one beside where its original would go, named
    /// after it, and any other media in `media/<the folder it was in>/`.
    func destination(for url: URL, real: String, kind: ArchivedKind) -> String {
        if kind == .lut { return "assets/lut/\(url.lastPathComponent)" }
        if let shared = options.sharedLibrary {
            var library = shared.root.lastPathComponent
            while library.hasPrefix(".") { library.removeFirst() }
            if library.isEmpty { library = SharedLibrary.defaultName }
            if let relative = shared.relativePath(of: url) ?? shared.relativePath(of: URL(fileURLWithPath: real)) {
                return "media/\(library)/\(relative)"
            }
            if let assetsRoot = options.assetsRoot, let original = AssetLibrary.sharedOriginal(of: URL(fileURLWithPath: real), assetsRoot: assetsRoot) {
                let stem = (original as NSString).deletingPathExtension
                return "media/\(library)/\(stem).\(URL(fileURLWithPath: real).pathExtension)"
            }
        }
        return Self.mediaDestination(for: url)
    }

    /// Where an outside media file goes: `media/<the folder it was in>/<its
    /// name>`, so a take's files and their sidecar stay together and a
    /// folder name like `music` or `sfx` still says what's in it.
    static func mediaDestination(for url: URL) -> String {
        let name = url.lastPathComponent
        var parent = url.deletingLastPathComponent().lastPathComponent
        while parent.hasPrefix(".") { parent.removeFirst() }
        if parent.isEmpty || parent == "/" || MediaScanner.isSkippedFolder(name: parent) { return "media/\(name)" }
        return "media/\(parent)/\(name)"
    }

    /// The take a record-it file belongs to: `main` for `main-camera.mov`.
    static func takeBase(_ fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        for role in ["camera", "screen"] {
            let suffix = "-\(role)"
            if stem.lowercased().hasSuffix(suffix), stem.count > suffix.count { return String(stem.dropLast(suffix.count)) }
        }
        return nil
    }

    /// The path with every link resolved, or nil when nothing is there.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

/// Progress across a run's files, reported at most every few hundredths.
private final class Meter {
    let total: Int64
    let files: Int
    let report: ((ArchiveProgress) -> Void)?
    private(set) var done: Int64 = 0
    private var filesDone = 0
    private var message = ""
    private var lastFraction = -1.0
    private var lastTime = Date.distantPast

    init(total: Int64, files: Int, report: ((ArchiveProgress) -> Void)?) {
        self.total = max(total, 1)
        self.files = files
        self.report = report
    }

    func say(_ message: String) {
        self.message = message
        send(force: true)
    }

    func set(_ done: Int64) {
        self.done = max(self.done, min(done, total))
        send(force: false)
    }

    func fileDone() {
        filesDone += 1
        send(force: true)
    }

    private func send(force: Bool) {
        guard let report else { return }
        let fraction = Double(done) / Double(total)
        let now = Date()
        guard force || fraction - lastFraction >= 0.005 || now.timeIntervalSince(lastTime) >= 0.25 else { return }
        lastFraction = fraction
        lastTime = now
        report(ArchiveProgress(message: message, fraction: fraction, filesDone: filesDone, filesTotal: files))
    }
}
