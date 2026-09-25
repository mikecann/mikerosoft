import CoreGraphics
import Foundation
import TandemCore
import TandemMedia
import TandemRender

/// The operations agents use, on one open project. The HTTP server, the
/// CLI and the MCP server are thin layers over this.
///
/// Every edit goes through the session's `ProjectCoordinator`, so it's
/// validated, undoable, journaled and announced like an edit made in the
/// app. The service is safe to call from any thread.
public final class TandemService: @unchecked Sendable {
    public enum Mode: Sendable {
        /// The app or `tandem serve` holds the project open for a while.
        case hosted
        /// The CLI or MCP server opened the project for one call and closes
        /// it straight after. Undo history lives on disk in this mode.
        case headless
    }

    public let session: ProjectSession
    public let mode: Mode
    public let analysis: AnalysisSource
    public let renderer: RenderBackend
    public let events = EventHub()
    /// Set by the app to capture its window for `screenshot`.
    public var screenshotProvider: (@Sendable () async throws -> Data)?

    public var coordinator: ProjectCoordinator { session.coordinator }
    public var folder: ProjectFolder { session.folder }

    let history: HeadlessHistory
    /// Serialises snapshot, apply and history bookkeeping so a before
    /// snapshot always belongs to the edit recorded with it.
    private let editLock = NSLock()
    private let stateLock = NSLock()
    private var exports: [String: ExportJob] = [:]
    private var pendingRestore: (kind: ServiceEvent.Kind, label: String, author: String)?
    private var coordinatorToken: UUID?
    private var jobsToken: UUID?

    public init(
        session: ProjectSession,
        mode: Mode = .hosted,
        analysis: AnalysisSource? = nil,
        renderer: RenderBackend = DefaultRenderBackend()
    ) {
        self.session = session
        self.mode = mode
        self.analysis = analysis ?? session.analysis
        self.renderer = renderer
        self.history = HeadlessHistory(projectURL: session.fileURL)
        // Observers run inside the coordinator's queue, so they must not
        // call back into the coordinator. They only record the event.
        coordinatorToken = session.coordinator.observe { [weak self] change in
            self?.record(change)
        }
        jobsToken = self.analysis.observeJobs { [weak self] jobs in
            self?.events.publish { ServiceEvent(seq: $0, kind: .jobs, jobs: jobs) }
        }
    }

    /// Stops observing the project and ends watch streams. Call before
    /// closing the session.
    public func shutdown() {
        if let token = coordinatorToken { coordinator.removeObserver(token) }
        if let token = jobsToken { analysis.removeJobsObserver(token) }
        coordinatorToken = nil
        jobsToken = nil
        events.finishAll()
    }

    private func record(_ change: ProjectCoordinator.ChangeEvent) {
        stateLock.lock()
        let restore = change.kind == .reload ? pendingRestore : nil
        if restore != nil { pendingRestore = nil }
        stateLock.unlock()
        let kind: ServiceEvent.Kind
        switch change.kind {
        case .edit: kind = .edit
        case .undo: kind = .undo
        case .redo: kind = .redo
        case .reload: kind = restore?.kind ?? .reload
        }
        events.publish {
            ServiceEvent(
                seq: $0, kind: kind, revision: change.revision,
                label: restore?.label ?? change.label, author: restore?.author ?? change.author
            )
        }
    }

    /// Runs any call against this service with JSON in and out, for the
    /// HTTP server.
    public func handle(_ operation: ServiceOperation, body: Data, context: CallContext) async throws -> Data {
        try await handle(operation.callType, body: body, context: context)
    }

    private func handle<C: ServiceCall>(_ type: C.Type, body: Data, context: CallContext) async throws -> Data {
        let call = try ServiceJSON.decodeRequest(C.self, from: body)
        let result = try await call.run(on: self, context: context)
        return try ServiceJSON.encoder().encode(result)
    }

    // MARK: - status

    public func status() -> StatusResult {
        let (project, revision) = coordinator.snapshot()
        let lock = ProjectSession.readLock(for: session.fileURL)
        let owner = lock.map { OwnerInfo(owner: $0.owner.rawValue, pid: $0.pid, started: $0.started, port: $0.port) }
        let undo = coordinator.undoLabel ?? (mode == .headless ? history.peekUndo(at: revision)?.label : nil)
        let redo = coordinator.redoLabel ?? (mode == .headless ? history.peekRedo(at: revision)?.label : nil)
        stateLock.lock()
        let running = exports.values.sorted { $0.id < $1.id }
        stateLock.unlock()
        return StatusResult(
            name: project.name,
            path: session.fileURL.path,
            revision: revision,
            savedRevision: session.savedRevision,
            dirty: session.isDirty,
            duration: project.duration,
            width: project.settings.width,
            height: project.settings.height,
            frameRate: project.settings.frameRate.framesPerSecond,
            tracks: project.allTracks.count,
            clips: project.allTracks.reduce(0) { $0 + $1.clips.count },
            media: project.media.count,
            markers: project.markers.count,
            undo: undo,
            redo: redo,
            openIn: owner,
            headless: mode == .headless,
            jobs: analysis.jobs,
            exports: running,
            recoveredEdits: session.recoveredEdits,
            apiVersion: TandemAPI.version
        )
    }

    // MARK: - media

    public func media(refresh: Bool) async throws -> MediaResult {
        var added: [String] = []
        if refresh {
            added = try await session.refreshMedia()
        }
        let (project, revision) = coordinator.snapshot()
        var usage: [String: Int] = [:]
        for clip in project.allTracks.flatMap(\.clips) {
            if let id = clip.mediaID { usage[id, default: 0] += 1 }
        }
        let jobs = analysis.jobs
        let items = project.media.map { item in
            MediaInfo(
                id: item.id,
                path: item.path,
                kind: item.kind,
                role: item.role,
                duration: item.duration,
                width: item.width,
                height: item.height,
                frameRate: item.frameRate?.framesPerSecond,
                hasVideo: item.hasVideo,
                hasAudio: item.hasAudio,
                takeID: item.takeID,
                takeOffset: item.takeOffset,
                clips: usage[item.id] ?? 0,
                exists: FileManager.default.fileExists(atPath: folder.url(for: item).path),
                analysis: analysisStates(for: item, jobs: jobs)
            )
        }
        return MediaResult(revision: revision, added: added, items: items)
    }

    /// The analyses that apply to a file, and how far along each is.
    func analysisStates(for item: MediaItem, jobs: [JobStatus]) -> [String: AnalysisState] {
        var kinds: [AnalysisKind] = []
        if item.hasVideo || item.kind == .image { kinds.append(.thumbnails) }
        if item.hasVideo && item.kind == .video { kinds.append(.proxy) }
        if item.hasAudio { kinds += [.waveform, .loudness, .transcript] }
        if item.role == .camera {
            if item.hasVideo { kinds.append(.matte) }
            if item.hasAudio { kinds.append(.isolatedVoice) }
        }
        var states: [String: AnalysisState] = [:]
        for kind in kinds {
            if analysis.isReady(kind, for: item) {
                states[kind.rawValue] = AnalysisState(state: "ready")
            } else if let job = jobs.last(where: { $0.mediaID == item.id && $0.kind == kind }) {
                states[kind.rawValue] = AnalysisState(state: job.state.rawValue, progress: job.state == .running ? job.progress : nil)
            } else {
                states[kind.rawValue] = AnalysisState(state: "none")
            }
        }
        return states
    }

    // MARK: - timeline

    public func timeline(from: Time?, to: Time?, format: TimelineRequest.Format, words: Bool) throws -> TimelineResult {
        if let from, let to, to <= from {
            throw ServiceError(.badRequest, "`to` (\(to)) must be after `from` (\(from)).")
        }
        let (project, revision) = coordinator.snapshot()
        switch format {
        case .json:
            return TimelineResult(revision: revision, text: nil, project: TimelineDump.filtered(project, from: from, to: to))
        case .text:
            var options = TimelineDump.Options()
            options.from = from
            options.to = to
            if words {
                options.transcripts = { [analysis] item in analysis.transcript(for: item) }
            }
            let text = TimelineDump.render(project, revision: revision, options: options)
            return TimelineResult(revision: revision, text: text, project: nil)
        }
    }

    // MARK: - transcripts

    public func transcript(id: String?, from: Time?, to: Time?) throws -> TranscriptResult {
        let (project, revision) = coordinator.snapshot()
        func keep(_ start: Time, _ end: Time) -> Bool {
            if let from, end <= from { return false }
            if let to, start >= to { return false }
            return true
        }
        guard let id else {
            let map = TranscriptTools.speechMap(project, analysis: analysis)
            let words = map.words.filter { keep($0.start, $0.end) }.map {
                WordTiming(text: $0.text, start: $0.start, end: $0.end, clipID: $0.clipID, confidence: $0.confidence)
            }
            return TranscriptResult(revision: revision, scope: "timeline", id: nil, timelineTimes: true, words: words, missing: map.missing)
        }
        if let item = project.media(id) {
            guard let transcript = analysis.transcript(for: item) else {
                throw ServiceError(.unavailable, "\(item.path) has no transcript yet. Transcripts are made in the background; `tandem media` shows progress.")
            }
            let words = transcript.words.filter { keep($0.start, $0.end) }.map {
                WordTiming(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence)
            }
            return TranscriptResult(revision: revision, scope: "media", id: id, timelineTimes: false, words: words, missing: [])
        }
        if let clip = project.clip(id) {
            guard let mediaID = clip.mediaID, let item = project.media(mediaID) else {
                throw ServiceError(.invalid, "Clip \(id) isn't a media clip, so it has no transcript.")
            }
            guard item.hasAudio else {
                throw ServiceError(.invalid, "Clip \(id) plays \(item.path), which has no sound.")
            }
            guard let transcript = analysis.transcript(for: item) else {
                throw ServiceError(.unavailable, "\(item.path) has no transcript yet. Transcripts are made in the background; `tandem media` shows progress.")
            }
            let words = TranscriptTools.words(transcript, playedBy: clip).filter { keep($0.start, $0.end) }.map {
                WordTiming(text: $0.text, start: $0.start, end: $0.end, clipID: $0.clipID, confidence: $0.confidence)
            }
            return TranscriptResult(revision: revision, scope: "clip", id: id, timelineTimes: true, words: words, missing: [])
        }
        throw ServiceError(.notFound, "No media or clip with ID \(id).")
    }

    public func search(phrase: String, limit: Int?) throws -> SearchResult {
        guard !TranscriptTools.tokens(phrase).isEmpty else {
            throw ServiceError(.badRequest, "Search for at least one word.")
        }
        let (project, revision) = coordinator.snapshot()
        var found = TranscriptTools.search(phrase, in: project, analysis: analysis)
        if let limit, limit >= 0 {
            found.hits = Array(found.hits.prefix(limit))
            found.unused = Array(found.unused.prefix(limit))
        }
        return SearchResult(revision: revision, phrase: phrase, hits: found.hits, unused: found.unused, missing: found.missing)
    }

    public func pauses(minimum: Time, from: Time?, to: Time?) throws -> PausesResult {
        guard minimum > .zero else { throw ServiceError(.badRequest, "`min` must be more than 0 seconds.") }
        let (project, revision) = coordinator.snapshot()
        let map = TranscriptTools.speechMap(project, analysis: analysis)
        let pauses = TranscriptTools.pauses(in: map, minimum: minimum, from: from, to: to)
        let total = pauses.reduce(Time.zero) { $0 + $1.duration }
        return PausesResult(revision: revision, minimum: minimum, pauses: pauses, total: total, missing: map.missing)
    }

    public func tighten(_ request: TightenRequest, context: CallContext) throws -> TightenResult {
        let minimum = Time(seconds: request.min ?? TranscriptTools.defaultMinimum)
        let keep = Time(seconds: request.keep ?? TranscriptTools.defaultKeep)
        guard minimum > .zero else { throw ServiceError(.badRequest, "`min` must be more than 0 seconds.") }
        guard keep >= .zero, keep < minimum else {
            throw ServiceError(.badRequest, "`keep` (\(TimeText.duration(keep))) must be shorter than `min` (\(TimeText.duration(minimum))).")
        }
        let (project, revision) = coordinator.snapshot()
        if let expected = request.expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        let map = TranscriptTools.speechMap(project, analysis: analysis)
        let pauses = TranscriptTools.pauses(in: map, minimum: minimum, from: request.from, to: request.to)
        let cuts = TranscriptTools.plan(pauses, keep: keep, frameRate: project.settings.frameRate)
        let commands = TranscriptTools.commands(for: cuts)
        let removed = cuts.reduce(Time.zero) { $0 + $1.cut.duration }

        var warnings: [String] = []
        if !map.missing.isEmpty {
            let names = map.missing.compactMap { project.media($0)?.path }.joined(separator: ", ")
            warnings.append("No transcript yet for \(names), so pauses there aren't included.")
        }
        let locked = project.allTracks.filter { $0.rippleMode == .cut && $0.locked }.map(\.name)
        if !locked.isEmpty && !cuts.isEmpty {
            let message = "Track \(locked.map { "\"\($0)\"" }.joined(separator: ", ")) is locked, so tightening would put the take out of sync. Unlock it first."
            if request.apply == true { throw ServiceError(.locked, message) }
            warnings.append(message)
        }

        var result = TightenResult(
            revision: revision, minimum: minimum, keep: keep, cuts: cuts, removed: removed,
            durationBefore: project.duration, durationAfter: project.duration - removed,
            commands: commands, applied: nil, warnings: warnings, missing: map.missing
        )
        guard !cuts.isEmpty else { return result }
        let label = request.label ?? "Tighten \(cuts.count) pause\(cuts.count == 1 ? "" : "s") to \(TimeText.duration(keep))"
        let apply = ApplyRequest(
            label: label, author: request.author, commands: commands,
            expectedRevision: revision, dryRun: request.apply != true
        )
        let applied = try self.apply(apply, context: context)
        result.durationAfter = applied.duration
        result.warnings += applied.warnings
        if request.apply == true { result.applied = applied }
        return result
    }

    // MARK: - apply

    public func apply(_ request: ApplyRequest, context: CallContext) throws -> ApplyResult {
        guard !request.commands.isEmpty else {
            throw ServiceError(.badRequest, "The batch has no commands.")
        }
        let batch = EditBatch(
            label: request.label ?? EditCommand.label(for: request.commands),
            author: request.author ?? context.author,
            commands: request.commands,
            expectedRevision: request.expectedRevision,
            idempotencyKey: request.idempotencyKey
        )
        if request.dryRun == true {
            return try dryRun(batch)
        }
        editLock.lock()
        defer { editLock.unlock() }
        if mode == .headless, let key = batch.idempotencyKey, var previous = history.result(forKey: key) {
            previous.repeated = true
            return previous
        }
        let (before, beforeRevision) = coordinator.snapshot()
        let commit: ProjectCoordinator.CommitResult
        do {
            commit = try coordinator.apply(batch)
        } catch {
            throw ServiceError.wrap(error)
        }
        let repeated = commit.revision <= beforeRevision
        let after = coordinator.project
        let diff = repeated ? ClipDiff() : ClipDiff(before, after)
        let result = ApplyResult(
            revision: commit.revision, label: commit.label, author: commit.author,
            createdIDs: commit.createdIDs, warnings: commit.warnings, dryRun: false, repeated: repeated,
            added: diff.added, removed: diff.removed, changed: diff.changed, duration: after.duration
        )
        if mode == .headless && !repeated {
            history.recordEdit(label: batch.label, author: batch.author, before: before, beforeRevision: beforeRevision, afterRevision: commit.revision)
            if let key = batch.idempotencyKey { history.remember(key: key, result: result) }
        }
        return result
    }

    /// Applies a batch to a copy of the project, the way the coordinator
    /// would, and reports the outcome without committing.
    func dryRun(_ batch: EditBatch) throws -> ApplyResult {
        let (project, revision) = coordinator.snapshot()
        if let expected = batch.expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        var working = project
        var context = EditContext()
        for (index, command) in batch.commands.enumerated() {
            do {
                try Editing.apply(command, to: &working, context: &context)
            } catch let error as EditError where batch.commands.count > 1 {
                throw ServiceError.wrap(EditError.invalid("command \(index + 1) of \(batch.commands.count): \(error.description)"))
            } catch {
                throw ServiceError.wrap(error)
            }
        }
        let issues = ProjectValidator.validate(working)
        if let first = issues.first(where: { $0.severity == .error }) {
            throw ServiceError(.invalid, "Invalid edit: \(first.message)")
        }
        let diff = ClipDiff(project, working)
        return ApplyResult(
            revision: revision, label: batch.label, author: batch.author,
            createdIDs: context.createdIDs,
            warnings: context.warnings + issues.filter { $0.severity == .warning }.map(\.message),
            dryRun: true, repeated: false,
            added: diff.added, removed: diff.removed, changed: diff.changed, duration: working.duration
        )
    }

    // MARK: - undo and redo

    public func undo(expectedRevision: Int?) throws -> UndoResult {
        try step(.undo, expectedRevision: expectedRevision)
    }

    public func redo(expectedRevision: Int?) throws -> UndoResult {
        try step(.redo, expectedRevision: expectedRevision)
    }

    private func step(_ kind: ServiceEvent.Kind, expectedRevision: Int?) throws -> UndoResult {
        editLock.lock()
        defer { editLock.unlock() }
        let (current, revision) = coordinator.snapshot()
        if let expected = expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        let action = kind == .undo ? "undo" : "redo"
        if let result = kind == .undo ? coordinator.undo() : coordinator.redo() {
            let label = result.label.replacingOccurrences(of: kind == .undo ? "Undo " : "Redo ", with: "")
            return UndoResult(action: action, revision: result.revision, label: label, author: result.author)
        }
        // Nothing in memory: fall back to the history of headless edits,
        // which is only used while the project hasn't moved on since.
        let entry = kind == .undo ? history.peekUndo(at: revision) : history.peekRedo(at: revision)
        guard let entry else {
            throw kind == .undo
                ? ServiceError(.nothingToUndo, "Nothing to undo.", revision: revision)
                : ServiceError(.nothingToRedo, "Nothing to redo.", revision: revision)
        }
        stateLock.lock()
        pendingRestore = (kind, entry.label, entry.author)
        stateLock.unlock()
        coordinator.reload(entry.project)
        let newRevision = coordinator.revision
        if kind == .undo {
            history.didUndo(at: revision, replaced: current, newRevision: newRevision)
        } else {
            history.didRedo(at: revision, replaced: current, newRevision: newRevision)
        }
        return UndoResult(action: action, revision: newRevision, label: entry.label, author: entry.author)
    }

    // MARK: - history and validate

    public func history(limit: Int) -> HistoryResult {
        let revision = coordinator.revision
        var undo = coordinator.history(limit: limit).map { HistoryEntry(label: $0.label, author: $0.author) }
        var redo = coordinator.redoLabel
        if undo.isEmpty && redo == nil {
            undo = history.undoEntries(at: revision).prefix(limit).map { HistoryEntry(label: $0.label, author: $0.author) }
            redo = history.peekRedo(at: revision)?.label
        }
        let changes = events.events(after: 0).filter(\.isChange).suffix(limit)
        return HistoryResult(revision: revision, undo: undo, redo: redo, events: Array(changes))
    }

    public func validate() -> ValidateResult {
        let (project, revision) = coordinator.snapshot()
        var issues = ProjectValidator.validate(project)
        for item in project.media where !FileManager.default.fileExists(atPath: folder.url(for: item).path) {
            let users = project.allTracks.flatMap(\.clips).filter { $0.mediaID == item.id }.count
            let severity: ValidationIssue.Severity = users > 0 ? .error : .warning
            issues.append(ValidationIssue(severity, "Media file \(item.path) is missing\(users > 0 ? " and \(users) clip(s) use it" : "").", objectID: item.id))
        }
        return ValidateResult(revision: revision, ok: !issues.contains { $0.severity == .error }, issues: issues)
    }

    // MARK: - frames and renders

    /// Resolves an output path: absolute, `~/`, or relative to the project folder.
    public func outputURL(_ path: String) -> URL {
        folder.url(forPath: path).standardizedFileURL
    }

    func renderContext(_ project: Project, format: String?) throws -> RenderContext {
        if let format, format != "main", !project.settings.alternateFormats.contains(where: { $0.id == format }) {
            let known = project.settings.alternateFormats.map(\.id)
            throw ServiceError(.notFound, "No output format \"\(format)\". This project has: \((["main"] + known).joined(separator: ", ")).")
        }
        return RenderContext(
            project: project, folder: folder, analysis: session.analysis,
            useProxies: false, format: format == "main" ? nil : format
        )
    }

    /// Takes what a frame grab needs from the open project and returns the
    /// slow part, so a headless caller can close the project first.
    public func prepareFrame(_ request: FrameRequest) throws -> @Sendable () async throws -> ImageResult {
        let project = coordinator.project
        guard request.time >= .zero else { throw ServiceError(.badRequest, "The time can't be negative.") }
        let context = try renderContext(project, format: request.format)
        let size = context.renderSize
        var maxSize: CGSize?
        switch (request.maxWidth, request.maxHeight) {
        case let (w?, h?): maxSize = CGSize(width: w, height: h)
        case let (w?, nil): maxSize = CGSize(width: Double(w), height: Double(w) * size.height / max(size.width, 1))
        case let (nil, h?): maxSize = CGSize(width: Double(h) * size.width / max(size.height, 1), height: Double(h))
        case (nil, nil): maxSize = nil
        }
        let output = request.output.map(outputURL)
        let renderer = self.renderer
        let time = request.time
        return { [maxSize] in
            let data: Data
            do {
                data = try await renderer.pngData(context: context, at: time, maxSize: maxSize)
            } catch {
                throw ServiceError.wrap(error)
            }
            return try Self.deliver(data, to: output, time: time)
        }
    }

    public func screenshot(output: String?) async throws -> ImageResult {
        guard let provider = screenshotProvider else {
            throw ServiceError(.unavailable, "Screenshots capture the Tandem app's window, so they need the app open. Use `frame` for a rendered frame.")
        }
        let data = try await provider()
        return try Self.deliver(data, to: output.map(outputURL), time: nil)
    }

    static func deliver(_ data: Data, to output: URL?, time: Time?) throws -> ImageResult {
        guard let output else {
            return ImageResult(time: time, path: nil, png: data.base64EncodedString(), bytes: data.count)
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        return ImageResult(time: time, path: output.path, png: nil, bytes: data.count)
    }

    public func prepareClip(_ request: ClipRequest) throws -> @Sendable () async throws -> ExportOutcome {
        guard request.end > request.start else {
            throw ServiceError(.badRequest, "The clip's end (\(request.end)) must be after its start (\(request.start)).")
        }
        guard request.start >= .zero else { throw ServiceError(.badRequest, "The clip can't start before 0.") }
        var preset = try preset(named: request.preset, default: .review)
        preset.range = TimeRange(start: request.start, end: request.end)
        let output = request.output.map(outputURL)
            ?? folder.exportsFolder.appendingPathComponent("review \(TimeText.fileSafe(request.start))-\(TimeText.fileSafe(request.end)).mp4")
        return try prepareRender(preset: preset, output: output, format: preset.format)
    }

    public func prepareExport(_ request: ExportRequest) throws -> @Sendable () async throws -> ExportOutcome {
        var preset = try preset(named: request.preset, default: .youtube4K)
        if request.from != nil || request.to != nil {
            let project = coordinator.project
            let start = request.from ?? .zero
            let end = request.to ?? project.duration
            guard end > start else { throw ServiceError(.badRequest, "The export range is empty (\(start) to \(end)).") }
            preset.range = TimeRange(start: start, end: end)
        }
        if let format = request.format { preset.format = format }
        let output: URL
        if let path = request.output {
            output = outputURL(path)
        } else {
            let (project, revision) = coordinator.snapshot()
            output = uniqueURL(folder.exportsFolder.appendingPathComponent("\(project.name) r\(revision).mp4"))
        }
        return try prepareRender(preset: preset, output: output, format: preset.format)
    }

    func preset(named name: String?, default fallback: ExportPreset) throws -> ExportPreset {
        guard let name else { return fallback }
        guard let preset = ExportPreset.named(name) else {
            let known = ExportPreset.all.map(\.slugName).joined(separator: ", ")
            throw ServiceError(.notFound, "No export preset \"\(name)\". Presets: \(known).")
        }
        return preset
    }

    func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }

    private func prepareRender(preset: ExportPreset, output: URL, format: String?) throws -> @Sendable () async throws -> ExportOutcome {
        let project = coordinator.project
        let context = try renderContext(project, format: format)
        let renderer = self.renderer
        let id = IDs.make("exp")
        let path = output.path
        return { [weak self] in
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            self?.track(ExportJob(id: id, output: path, preset: preset.name))
            let reporter = ProgressReporter { progress in
                self?.track(ExportJob(id: id, output: path, preset: preset.name, progress: progress))
            }
            do {
                let result = try await renderer.export(context: context, preset: preset, output: output) { reporter.report($0) }
                self?.finish(ExportJob(id: id, output: path, preset: preset.name, progress: 1, state: .done))
                return ExportOutcome(
                    path: result.path, preset: preset.name, duration: result.duration,
                    integratedLUFS: result.integratedLUFS, truePeakDBTP: result.truePeakDBTP, elapsed: result.elapsed
                )
            } catch {
                let wrapped = ServiceError.wrap(error)
                self?.finish(ExportJob(id: id, output: path, preset: preset.name, state: .failed, message: wrapped.message))
                throw wrapped
            }
        }
    }

    private func track(_ job: ExportJob) {
        stateLock.lock()
        exports[job.id] = job
        stateLock.unlock()
        events.publish { ServiceEvent(seq: $0, kind: .export, export: job) }
    }

    private func finish(_ job: ExportJob) {
        stateLock.lock()
        exports.removeValue(forKey: job.id)
        stateLock.unlock()
        events.publish { ServiceEvent(seq: $0, kind: .export, export: job) }
    }

    // MARK: - loudness

    public func loudness(mediaID: String?) throws -> LoudnessResult {
        let project = coordinator.project
        var items = project.media.filter(\.hasAudio)
        if let mediaID {
            guard let item = project.media(mediaID) else { throw ServiceError(.notFound, "No media with ID \(mediaID).") }
            items = [item]
        }
        let jobs = analysis.jobs
        var measured: [String: Loudness] = [:]
        let media = items.map { item -> MediaLoudness in
            let loudness = analysis.loudness(for: item)
            measured[item.id] = loudness
            let state = loudness != nil ? "ready" : (jobs.last { $0.mediaID == item.id && $0.kind == .loudness }?.state.rawValue ?? "none")
            return MediaLoudness(
                mediaID: item.id, path: item.path, integratedLUFS: loudness?.integratedLUFS,
                truePeakDBTP: loudness?.truePeakDBTP, loudnessRange: loudness?.loudnessRange, state: state
            )
        }
        let wanted = Set(items.map(\.id))
        var clips: [ClipLevel] = []
        for track in project.audioTracks {
            for clip in track.clips {
                guard let id = clip.mediaID, wanted.contains(id) else { continue }
                let audio = clip.audio ?? AudioProperties()
                var normalizeGain: Double?
                if let target = audio.normalizeTo, let lufs = measured[id]?.integratedLUFS, lufs.isFinite {
                    normalizeGain = target - lufs
                }
                clips.append(ClipLevel(
                    clipID: clip.id, mediaID: id, track: track.name, gainDB: audio.gainDB,
                    normalizeTo: audio.normalizeTo, normalizeGainDB: normalizeGain
                ))
            }
        }
        return LoudnessResult(
            target: project.settings.loudnessTarget, truePeakCeiling: project.settings.truePeakCeiling,
            media: media, clips: clips
        )
    }

    // MARK: - watch

    /// Waits until the project moves past `after` (default: now) or the
    /// timeout passes.
    public func watch(after: Int?, timeout: Double) async -> WatchResult {
        let start = after ?? coordinator.revision
        let limit = min(max(timeout, 0), 600)
        let coordinator = self.coordinator
        _ = await events.next(timeout: limit, unless: { coordinator.revision > start }) {
            $0.isChange && ($0.revision ?? 0) > start
        }
        let revision = coordinator.revision
        let changes = events.events(after: 0).filter { $0.isChange && ($0.revision ?? 0) > start }
        return WatchResult(revision: revision, changed: revision > start, events: changes, jobs: analysis.jobs)
    }
}

/// Throttles progress callbacks to about one per percent.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let handler: (Double) -> Void

    init(_ handler: @escaping (Double) -> Void) {
        self.handler = handler
    }

    func report(_ progress: Double) {
        lock.lock()
        let due = progress >= 1 || progress - last >= 0.01
        if due { last = progress }
        lock.unlock()
        if due { handler(progress) }
    }
}

/// Which clips a batch added, removed or changed.
struct ClipDiff {
    var added: [String] = []
    var removed: [String] = []
    var changed: [String] = []

    init() {}

    init(_ before: Project, _ after: Project) {
        let old = Dictionary(before.allTracks.flatMap { track in track.clips.map { ($0.id, ($0, track.id)) } }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(after.allTracks.flatMap { track in track.clips.map { ($0.id, ($0, track.id)) } }, uniquingKeysWith: { a, _ in a })
        for track in after.allTracks {
            for clip in track.clips {
                if let (previous, previousTrack) = old[clip.id] {
                    if previous != clip || previousTrack != track.id { changed.append(clip.id) }
                } else {
                    added.append(clip.id)
                }
            }
        }
        for track in before.allTracks {
            for clip in track.clips where new[clip.id] == nil { removed.append(clip.id) }
        }
    }
}
