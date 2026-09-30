import AppKit
import Foundation
import Observation
import TandemAPI
import TandemCore
import TandemMedia
import TandemRender

/// Left panel tabs. Transitions share a panel with effects and looks, so
/// they're a sub-tab of Effects rather than a tab of their own.
enum LibraryTab: String, CaseIterable, Identifiable {
    case media, text, transitions, effects, graphics, audio

    var id: String { rawValue }

    /// The tabs across the top of the library panel.
    static let shown: [LibraryTab] = [.media, .text, .effects, .graphics, .audio]

    /// The tab lit for this one: Effects for transitions.
    var shownTab: LibraryTab { self == .transitions ? .effects : self }

    var title: String {
        switch self {
        case .media: return "Media"
        case .text: return "Text"
        case .transitions: return "Transitions"
        case .effects: return "Effects"
        case .graphics: return "Graphics"
        case .audio: return "Audio"
        }
    }
}

/// Which inspector tab a clicked clip opens on.
enum InspectorTabs {
    /// A sound clip (a whoosh on SFX, music, the voice) has nothing on the
    /// Video or Colour tabs, so it turns to Audio; a picture with no sound
    /// (a title, a graphic, a still) turns from Audio to Video. Otherwise
    /// the tab stays: a camera clip is at home on any of them.
    static func fitting(_ current: InspectorTab, clip clipID: String, in project: Project) -> InspectorTab {
        guard let location = project.location(ofClip: clipID), let clip = project.clip(clipID) else { return current }
        if location.track.kind == .audio {
            return current == .video || current == .colour ? .audio : current
        }
        let hasSound = clip.mediaID.flatMap { project.media($0) }?.hasAudio ?? false
        return current == .audio && !hasSound ? .video : current
    }
}

/// Right panel tabs.
enum InspectorTab: String, CaseIterable, Identifiable {
    case video, colour, audio, info, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "Video"
        case .colour: return "Colour"
        case .audio: return "Audio"
        case .info: return "Info"
        case .activity: return "Activity"
        }
    }
}

/// A short message in the status bar.
struct StatusMessage: Equatable, Identifiable {
    enum Kind { case info, warning, error }
    let id = UUID()
    var kind: Kind
    var text: String
    var date = Date()

    static func == (a: StatusMessage, b: StatusMessage) -> Bool { a.id == b.id }
}

/// Everything one open project window shows and edits.
///
/// The project itself is read-only here: every change goes through
/// `apply(_:)`, which submits an `EditBatch` to the session's coordinator.
/// Agents edit through the same coordinator, and their edits arrive through
/// the change observer like any other.
@MainActor
@Observable
final class EditorModel {
    @ObservationIgnored let session: ProjectSession
    let playback = PlaybackController()
    let timeline = TimelineViewState()

    /// The latest committed project and its revision.
    private(set) var project: Project
    private(set) var revision: Int
    private(set) var isDirty = false
    /// Why the project couldn't be saved, until a save works. Autosave
    /// keeps trying; the status bar says so while it fails.
    private(set) var saveProblem: String?
    private(set) var activity = ActivityLog()
    private(set) var jobs: [JobStatus] = []
    /// Goes up when thumbnails, waveforms or transcripts land, so views
    /// that draw them look again.
    private(set) var artworkRevision = 0
    let exports = ExportQueue()

    // Selection
    var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue else { return }
            selectedTransitionID = selection.isEmpty ? selectedTransitionID : nil
            // A keyframe stays chosen only while its clip is selected.
            if let keyframe = selectedKeyframe, !selection.contains(keyframe.clipID) { selectedKeyframe = nil }
        }
    }
    /// The keyframe last clicked on the timeline, which Delete removes.
    var selectedKeyframe: KeyframeRef?
    var selectedTransitionID: String?
    /// The clip last clicked, which the inspector shows when a whole link
    /// group is selected. The inspector turns to a tab that fits it.
    var focusedClipID: String? {
        didSet {
            guard focusedClipID != oldValue, let focusedClipID else { return }
            let tab = InspectorTabs.fitting(inspectorTab, clip: focusedClipID, in: project)
            if tab != inspectorTab { inspectorTab = tab }
        }
    }

    // Timeline settings
    var tool: TimelineTool = .select
    var snapping = true
    var linkedSelection = true
    var rippleTrims = false
    var showTranscript = true
    var inPoint: Time?
    var outPoint: Time?

    // Panels
    var libraryTab: LibraryTab = .media {
        didSet { if libraryTab.shownTab == .effects { lastEffectsTab = libraryTab } }
    }
    /// Effects or transitions, whichever the Effects tab showed last, so
    /// coming back to it lands where you were.
    private(set) var lastEffectsTab: LibraryTab = .effects
    var inspectorTab: InspectorTab = .video
    var mediaSearch = ""
    var showExportSheet = false
    var showSafeMargins = false
    /// Z is held: viewer drags draw a zoom rectangle.
    var zoomKeyHeld = false
    var status: StatusMessage?
    /// Media being dragged from the browser, so the timeline can preview
    /// the drop before the pasteboard hands it over.
    var draggedMediaIDs: [String] = []
    /// A transform being dragged in the viewer or inspector, drawn before
    /// it's committed.
    var videoPreview: [String: VideoProperties] = [:]

    // Agents
    /// Who last reached the project over the API, for the agent chip.
    private(set) var agentPresence: AgentPresence?
    /// The API's port while it serves, for the agent chip.
    private(set) var apiPort: Int?
    /// Why the API isn't serving, when it couldn't start.
    private(set) var apiProblem: String?
    @ObservationIgnored private var apiHost: TandemAPIHost?
    @ObservationIgnored private var apiStopped = false

    // Review
    /// Agent edits Mike hasn't reviewed yet, from the session's review log.
    private(set) var reviewLog = ReviewLog()
    /// The same, placed on the timeline as it is now.
    private(set) var review = TimelineReview.empty
    @ObservationIgnored private var reviewToken: UUID?

    @ObservationIgnored private var lastScan: Date = .distantPast
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var jobToken: UUID?
    @ObservationIgnored private var dirtyTimer: Timer?
    @ObservationIgnored private var statusWork: DispatchWorkItem?

    init(session: ProjectSession) {
        self.session = session
        let snapshot = session.coordinator.snapshot()
        self.project = snapshot.project
        self.revision = snapshot.revision
        playback.makeContext = { [weak self] in
            guard let self else { return RenderContext(project: Project(name: ""), folder: ProjectFolder(root: URL(fileURLWithPath: "/"))) }
            return RenderContext(project: self.project, folder: self.session.folder, analysis: self.session.analysis)
        }
        playback.projectChanged(duration: project.duration, frameRate: project.settings.frameRate)
        observerToken = session.coordinator.observe { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        jobToken = session.analysis.observe { [weak self] jobs in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.jobsChanged(jobs) }
            }
        }
        // Listening first, so a change landing between the two isn't missed.
        reviewToken = session.review.observe { [weak self] log in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reviewChanged(log) }
            }
        }
        reviewChanged(session.review.log)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let dirty = self.session.isDirty
                if dirty != self.isDirty {
                    let saved = self.isDirty && !dirty
                    self.isDirty = dirty
                    // Now and then, a save refreshes the project's icon.
                    if saved { ProjectIcons.shared.refresh(.saved, for: self) }
                }
                self.noteSaveProblem(self.session.saveProblem)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dirtyTimer = timer
        exports.onFinish = { [weak self] job in
            guard let self else { return }
            switch job.state {
            case .done(let result):
                ExportSpeed.record(result)
                self.show(.info, "Exported \(job.output.lastPathComponent).")
            case .failed(let message):
                self.show(.error, "Export failed: \(message)")
            default:
                break
            }
        }
        if session.recoveredEdits {
            show(.warning, "Recovered edits that hadn't been saved when Tandem last closed.")
        }
    }

    /// Stops the API, observers and timers. Call before closing the session.
    func tearDown() {
        stopAPI()
        if let observerToken { session.coordinator.removeObserver(observerToken) }
        if let jobToken { session.analysis.removeObserver(jobToken) }
        if let reviewToken { session.review.removeObserver(reviewToken) }
        dirtyTimer?.invalidate()
        playback.invalidate()
        exports.cancelAll()
    }

    // MARK: - Names

    var fileURL: URL { session.fileURL }
    var folder: ProjectFolder { session.folder }
    var fileName: String { fileURL.lastPathComponent }
    var folderName: String { fileURL.deletingLastPathComponent().lastPathComponent }

    // MARK: - Editing

    /// Submits a batch. Failures show in the status bar and return nil.
    @discardableResult
    func apply(_ batch: EditBatch?) -> ProjectCoordinator.CommitResult? {
        guard let batch else { return nil }
        do {
            let result = try session.coordinator.apply(batch)
            refresh()
            if !result.warnings.isEmpty {
                show(.warning, result.warnings.joined(separator: " "))
            }
            return result
        } catch {
            show(.error, Self.describe(error))
            return nil
        }
    }

    func undo() {
        guard let result = session.coordinator.undo() else {
            show(.info, "Nothing to undo.")
            return
        }
        refresh()
        show(.info, result.label)
    }

    func redo() {
        guard let result = session.coordinator.redo() else {
            show(.info, "Nothing to redo.")
            return
        }
        refresh()
        show(.info, result.label)
    }

    /// Undoes `entryID` and everything after it.
    func undo(through entryID: Int) {
        guard let steps = activity.undoSteps(through: entryID) else { return }
        for _ in 0..<steps { session.coordinator.undo() }
        refresh()
        show(.info, steps == 1 ? "Undid 1 edit." : "Undid \(steps) edits.")
    }

    var undoLabel: String? { session.coordinator.undoLabel }
    var redoLabel: String? { session.coordinator.redoLabel }

    func save() {
        do {
            try session.save()
            isDirty = session.isDirty
            noteSaveProblem(nil)
            ProjectIcons.shared.refresh(.saved, for: self)
            show(.info, "Saved \(fileName).")
        } catch {
            noteSaveProblem(session.saveProblem ?? Self.describe(error), announce: false)
            show(.error, SaveProblem.message(file: fileName, reason: saveProblem ?? Self.describe(error)))
        }
    }

    /// Keeps `saveProblem` in step with the session, and says so in the
    /// status bar when saving starts failing or works again.
    func noteSaveProblem(_ problem: String?, announce: Bool = true) {
        guard problem != saveProblem else { return }
        let wasFailing = saveProblem != nil
        saveProblem = problem
        guard announce else { return }
        if let problem {
            show(.error, SaveProblem.message(file: fileName, reason: problem))
        } else if wasFailing {
            show(.info, "Saved \(fileName) again.")
        }
    }

    // MARK: - Change handling

    private func handle(_ event: ProjectCoordinator.ChangeEvent) {
        let before = project
        activity.record(event.kind, revision: event.revision, label: event.label, author: event.author)
        refresh()
        guard !ActivityLog.isPerson(event.author), event.author != ActivityLog.systemAuthor else { return }
        // An agent's edit, undo or redo, through the API.
        let section = ChangeRegion.between(before, project).flatMap { ChangeRegion.section(at: $0.start, in: project) }
        var presence = agentPresence ?? AgentPresence(author: event.author, lastSeen: Date())
        presence.edited(by: event.author, section: section, at: Date())
        agentPresence = presence
        if event.kind == .edit {
            show(.info, "\(ActivityLog.displayName(event.author)): \(event.label)")
        }
    }

    // MARK: - API

    /// Serves the local API while the project is open, so the CLI and MCP
    /// reach this window instead of opening the file themselves. Agent
    /// edits come back through the coordinator like any other.
    /// `screenshot` captures the project window for `tandem screenshot`.
    func startAPI(screenshot: @escaping @Sendable () async throws -> Data) {
        Task { @MainActor [weak self] in
            guard let self, !self.apiStopped else { return }
            do {
                let host = try await TandemAPIHost.start(session: self.session, fontInstaller: LibraryFontInstaller.shared)
                // The window may have closed while the server started.
                guard !self.apiStopped else { return host.stop() }
                host.service.screenshotProvider = screenshot
                // Every call an agent makes, reads included, so the chip
                // knows who's connected.
                host.service.onCall = { [weak self] _, author in
                    Task { @MainActor in self?.agentCalled(author: author) }
                }
                self.apiHost = host
                self.apiPort = host.port
                self.apiProblem = nil
            } catch {
                self.apiProblem = Self.describe(error)
                self.show(.warning, "Agents can't reach this project: \(Self.describe(error))")
            }
        }
    }

    /// Stops serving. Call before closing the session.
    func stopAPI() {
        apiStopped = true
        apiHost?.stop()
        apiHost = nil
        apiPort = nil
    }

    /// An agent called the API. Edits also arrive through the coordinator,
    /// which records where they landed.
    private func agentCalled(author: String) {
        var presence = agentPresence ?? AgentPresence(author: author, lastSeen: Date())
        presence.looked(by: author, at: Date())
        agentPresence = presence
    }

    /// True while an agent keeps a watch stream open. Read by the agent
    /// chip on its own clock, as the count isn't observable.
    var agentsWatching: Bool {
        (apiHost?.service.events.subscriberCount ?? 0) > 0
    }

    /// Pulls the latest project from the coordinator.
    func refresh() {
        let snapshot = session.coordinator.snapshot()
        guard snapshot.revision != revision else { return }
        project = snapshot.project
        revision = snapshot.revision
        isDirty = session.isDirty
        let pruned = SelectionRules.pruned(selection, in: project)
        if pruned != selection { selection = pruned }
        if let keyframe = selectedKeyframe {
            let still = project.clip(keyframe.clipID).map { KeyframeEdits.parameters(in: $0, keyedAt: keyframe.time, tolerance: keyframeTolerance, among: keyframe.parameters) } ?? []
            selectedKeyframe = still.isEmpty ? nil : KeyframeRef(clipID: keyframe.clipID, time: keyframe.time, parameters: still)
        }
        if let id = selectedTransitionID, project.location(ofTransition: id) == nil { selectedTransitionID = nil }
        placeReview()
        playback.projectChanged(duration: project.duration, frameRate: project.settings.frameRate)
        checkFonts()
    }

    // MARK: - Review

    /// The review log changed: an agent's edit arrived, an undo put one
    /// back, or Mike marked them reviewed.
    func reviewChanged(_ log: ReviewLog) {
        guard log != reviewLog else { return }
        reviewLog = log
        placeReview()
    }

    /// Places the log's changes on the timeline as it is now, so the
    /// highlights follow their clips.
    private func placeReview() {
        let placed = TimelineReview.make(log: reviewLog, project: project)
        if placed != review { review = placed }
    }

    // MARK: - Fonts

    @ObservationIgnored private var fontsWork: Task<Void, Never>?
    /// Install failures already shown, so an offline Mac hears it once, not
    /// after every edit. The viewer's warnings keep naming the font.
    @ObservationIgnored private var fontFailuresShown: Set<String> = []

    /// Registers any new fonts in the project's assets/font, and installs
    /// the fonts built-in presets need (the caption preset's Tilt Warp) when
    /// a title uses one this Mac doesn't have. A title that stays in the
    /// wrong font shows in the viewer's warnings. The viewer draws again by
    /// itself when a font arrives.
    func checkFonts() {
        let folder = session.folder
        ProjectFonts.registerNew(in: folder)
        let project = self.project
        guard fontsWork == nil, ProjectFonts.missing(in: project).contains(where: { $0.presetID != nil }) else { return }
        let file = fileURL
        fontsWork = Task { @MainActor [weak self] in
            let outcome = await PresetFonts.install(missingFrom: project, folder: folder, projectFile: file, installer: LibraryFontInstaller.shared)
            guard let self else { return }
            self.fontsWork = nil
            for font in outcome.installed {
                self.show(.info, "Installed \(font.name), the \(font.presetID) preset's font, into the project.")
            }
            if let failure = outcome.failures.first(where: { !self.fontFailuresShown.contains($0) }) {
                self.fontFailuresShown.insert(failure)
                self.show(.warning, failure)
            }
        }
    }

    // MARK: - Analysis

    private func jobsChanged(_ new: [JobStatus]) {
        let finished = JobChanges.newlyDone(old: jobs, new: new)
        jobs = new
        guard !finished.isEmpty else { return }
        if JobChanges.affectsArtwork(finished) { artworkRevision += 1 }
        // A new proxy or matte changes what the viewer can play.
        if JobChanges.affectsPlayback(finished) { playback.scheduleRebuild(delay: 0.5) }
    }

    // MARK: - Media

    /// Looks for files added to the project folder, at most every
    /// `interval` seconds. Runs when the project opens and whenever its
    /// window comes to the front, so files dropped in from Finder or
    /// record-it show up without asking.
    func rescanMedia(ifOlderThan interval: TimeInterval = 20, announce: Bool = false) {
        guard !scanning, Date().timeIntervalSince(lastScan) > interval else { return }
        scanning = true
        lastScan = Date()
        Task { @MainActor in
            defer { self.scanning = false }
            do {
                let found = try await self.session.refreshMedia()
                self.refresh()
                if !found.isEmpty {
                    self.show(.info, "Found \(found.count) new \(found.count == 1 ? "file" : "files") in \(self.folderName)/.")
                } else if announce {
                    self.show(.info, "No new files in \(self.folderName)/.")
                }
            } catch {
                if announce { self.show(.error, "Couldn't scan the folder: \(Self.describe(error))") }
            }
        }
    }

    // MARK: - Status

    func show(_ kind: StatusMessage.Kind, _ text: String) {
        status = StatusMessage(kind: kind, text: text)
        statusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.status = nil }
        }
        statusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .error ? 8 : 4), execute: work)
    }

    static func describe(_ error: Error) -> String {
        if let edit = error as? EditError { return edit.description }
        return error.localizedDescription
    }

    // MARK: - Convenience

    var playhead: Time { playback.time }
    var frameRate: FrameRate { project.settings.frameRate }

    /// The clip the inspector shows: the first selected clip in timeline
    /// order, preferring picture over sound.
    var primaryClipID: String? {
        if let focused = focusedClipID, selection.contains(focused) { return focused }
        let ordered = TimelineEdits.ordered(selection, in: project)
        // What's under the playhead first, a camera clip over its screen
        // clip, then any picture, then sound.
        let video = ordered.filter { project.location(ofClip: $0)?.track.kind == .video }
        let time = playback.time
        let here = video.filter { id in project.clip(id).map { $0.start <= time && time < $0.end } ?? false }
        func camera(_ ids: [String]) -> String? {
            ids.first { id in project.clip(id).flatMap { media(for: $0) }?.role == .camera }
        }
        return camera(here) ?? here.first ?? camera(video) ?? video.first ?? ordered.first
    }

    var inOutRange: TimeRange? {
        guard let inPoint, let outPoint, outPoint > inPoint else { return nil }
        return TimeRange(start: inPoint, end: outPoint)
    }

    func media(for clip: Clip) -> MediaItem? {
        clip.mediaID.flatMap { project.media($0) }
    }
}

/// The timeline's zoom and scroll, shared by the AppKit timeline and the
/// SwiftUI zoom slider.
@MainActor
@Observable
final class TimelineViewState {
    // Zoom and scroll are stored apart so the zoom slider, which reads
    // only the zoom, doesn't update on every step of a scroll.
    private var pixelsPerSecond = TimelineScale(pixelsPerSecond: 12).pixelsPerSecond
    private var scrollSeconds = 0.0

    var scale: TimelineScale {
        get { TimelineScale(pixelsPerSecond: pixelsPerSecond, scrollSeconds: scrollSeconds) }
        set {
            if newValue.pixelsPerSecond != pixelsPerSecond { pixelsPerSecond = newValue.pixelsPerSecond }
            if newValue.scrollSeconds != scrollSeconds { scrollSeconds = newValue.scrollSeconds }
        }
    }
    /// Pixels scrolled down when the tracks don't fit.
    var verticalOffset: CGFloat = 0
    /// Width of the lanes area, kept up to date by the view.
    var lanesWidth: CGFloat = 1_200
    /// Set when the view should fit the whole timeline on its next layout.
    var fitPending = true
    /// Lane heights the user has dragged, by track ID.
    var trackHeights: [String: CGFloat] = [:]
    /// A track whose name the headers should open for typing, set when a
    /// new track is added.
    var renamingTrackID: String?

    /// Zoom as 0...1 for the slider, on a log scale.
    var zoomFraction: Double {
        get {
            let low = log(TimelineScale.minimumPixelsPerSecond)
            let high = log(TimelineScale.maximumPixelsPerSecond)
            return (log(pixelsPerSecond) - low) / (high - low)
        }
        set {
            let low = log(TimelineScale.minimumPixelsPerSecond)
            let high = log(TimelineScale.maximumPixelsPerSecond)
            let target = exp(low + min(max(newValue, 0), 1) * (high - low))
            zoom(by: target / pixelsPerSecond, anchorX: nil)
        }
    }

    /// Zooms around `anchorX`, or the playhead's position when nil.
    @ObservationIgnored var playheadX: (() -> CGFloat?)?

    func zoom(by factor: Double, anchorX: CGFloat?) {
        let anchor = anchorX ?? playheadX?().map { min(max($0, 0), lanesWidth) } ?? lanesWidth / 2
        scale.zoom(by: factor, anchorX: anchor)
    }

    func fit(_ duration: Time) {
        scale = TimelineScale.fitting(duration, width: lanesWidth)
        fitPending = false
    }
}
