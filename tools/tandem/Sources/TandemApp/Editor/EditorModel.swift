import AppKit
import Foundation
import Observation
import TandemAPI
import TandemCore
import TandemMedia
import TandemRender

/// Left panel tabs, from the top bar.
enum LibraryTab: String, CaseIterable, Identifiable {
    case media, text, transitions, effects, graphics, audio

    var id: String { rawValue }

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
    private(set) var activity = ActivityLog()
    private(set) var jobs: [JobStatus] = []
    let exports = ExportQueue()

    // Selection
    var selection: Set<String> = [] {
        didSet { if selection != oldValue { selectedTransitionID = selection.isEmpty ? selectedTransitionID : nil } }
    }
    var selectedTransitionID: String?
    /// The clip last clicked, which the inspector shows when a whole link
    /// group is selected.
    var focusedClipID: String?

    // Timeline settings
    var tool: TimelineTool = .select
    var snapping = true
    var linkedSelection = true
    var rippleTrims = false
    var showTranscript = true
    var inPoint: Time?
    var outPoint: Time?

    // Panels
    var libraryTab: LibraryTab = .media
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
                MainActor.assumeIsolated { self?.jobs = jobs }
            }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let dirty = self.session.isDirty
                if dirty != self.isDirty { self.isDirty = dirty }
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

    /// Stops observers and timers. Call before closing the session.
    func tearDown() {
        if let observerToken { session.coordinator.removeObserver(observerToken) }
        if let jobToken { session.analysis.removeObserver(jobToken) }
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
            show(.info, "Saved \(fileName).")
        } catch {
            show(.error, "Couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: - Change handling

    private func handle(_ event: ProjectCoordinator.ChangeEvent) {
        activity.record(event.kind, revision: event.revision, label: event.label, author: event.author)
        refresh()
        if !ActivityLog.isPerson(event.author) && event.author != ActivityLog.systemAuthor && event.kind == .edit {
            show(.info, "\(ActivityLog.displayName(event.author)): \(event.label)")
        }
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
        if let id = selectedTransitionID, project.location(ofTransition: id) == nil { selectedTransitionID = nil }
        playback.projectChanged(duration: project.duration, frameRate: project.settings.frameRate)
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
    var scale = TimelineScale(pixelsPerSecond: 12)
    /// Pixels scrolled down when the tracks don't fit.
    var verticalOffset: CGFloat = 0
    /// Width of the lanes area, kept up to date by the view.
    var lanesWidth: CGFloat = 1_200
    /// Set when the view should fit the whole timeline on its next layout.
    var fitPending = true

    /// Zoom as 0...1 for the slider, on a log scale.
    var zoomFraction: Double {
        get {
            let low = log(TimelineScale.minimumPixelsPerSecond)
            let high = log(TimelineScale.maximumPixelsPerSecond)
            return (log(scale.pixelsPerSecond) - low) / (high - low)
        }
        set {
            let low = log(TimelineScale.minimumPixelsPerSecond)
            let high = log(TimelineScale.maximumPixelsPerSecond)
            let target = exp(low + min(max(newValue, 0), 1) * (high - low))
            zoom(by: target / scale.pixelsPerSecond, anchorX: nil)
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
