import AppKit
import SwiftUI
import TandemAPI
import TandemAssets
import TandemCore

/// One project window: the Graphite layout around an `EditorModel`.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, EditorCommandHandling {
    let model: EditorModel
    let actions: EditorActions
    private let router: KeyboardRouter
    /// Called once the window has closed and the session is released.
    var onClose: ((ProjectWindowController) -> Void)?
    /// File > Archive project…, while its sheet is up.
    private var archiveSheet: ArchiveSheetController?
    /// Timeline > Save selection as segment…, while its sheet is up.
    private var segmentSheet: SaveSegmentSheetController?

    init(model: EditorModel, keymap: Keymap, frame: NSRect? = nil) {
        self.model = model
        self.router = KeyboardRouter(keymap: keymap)
        self.actions = EditorActions(model: model)
        let window = EditorWindow(
            contentRect: frame ?? Self.defaultFrame(),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = model.project.name
        window.representedURL = model.fileURL
        window.backgroundColor = Theme.window.ns
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1_080, height: 660)
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        // The controller owns the window; AppKit mustn't release it too.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        // It opens where the last one was, unless it's replacing a window
        // (a new version) and has that one's frame.
        shouldCascadeWindows = false
        let others = NSApplication.shared.windows.filter { $0 is EditorWindow && $0 !== window && $0.isVisible }.map(\.frame)
        if frame == nil, let placed = WindowPlacement.restored(screens: NSScreen.screens.map(\.visibleFrame), occupied: others, for: model.fileURL) {
            window.setFrame(placed, display: false)
        }
        window.delegate = self
        actions.controller = self
        restoreTimeline()
        let root = EditorRootView(model: model, actions: actions)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
        router.install(on: window)
        router.perform = { [weak self] command in self?.actions.perform(command) ?? false }
        router.step = { [weak self] frames in self?.model.playback.step(frames: frames) }
        router.isBlocked = { [weak self] in self?.model.showExportSheet ?? false }
        router.holdChanged = { [weak self] key, down in
            if key == "z" { self?.model.zoomKeyHeld = down }
        }
        window.layoutTrafficLights()
        // Fonts the project carries in assets/font, so its titles look the
        // same here as on the Mac that made them, and the fonts its presets
        // need that aren't here yet.
        model.checkFonts()
        // A project opened without an icon gets one once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            ProjectIcons.shared.refresh(.opened, for: self.model)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_512, height: 982)
        let width = min(1_512, screen.width)
        let height = min(982, screen.height)
        return NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }

    var keymap: Keymap {
        get { router.keymap }
        set { router.keymap = newValue }
    }

    // MARK: - Commands

    @objc func performEditorCommand(_ sender: Any?) {
        guard let command = MainMenu.command(of: sender) else { return }
        // Text fields keep their own undo and select all.
        if let text = window?.firstResponder as? NSTextView, text.isEditable {
            switch command {
            case .undo: text.undoManager?.undo(); return
            case .redo: text.undoManager?.redo(); return
            case .selectAll: text.selectAll(nil); return
            default: break
            }
        }
        if !actions.perform(command) { NSSound.beep() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(revealProject(_:)) { return true }
        if item.action == #selector(archiveProject(_:)) { return archiveSheet == nil }
        if item.action == #selector(saveSelectionAsSegment(_:)) { return segmentSheet == nil && !model.selection.isEmpty }
        guard let command = MainMenu.command(of: item) else { return true }
        switch command {
        case .undo:
            item.title = model.undoLabel.map { "Undo \($0.lowercasedFirst)" } ?? "Undo"
        case .redo:
            item.title = model.redoLabel.map { "Redo \($0.lowercasedFirst)" } ?? "Redo"
        case .toggleSnapping: item.state = model.snapping ? .on : .off
        case .toggleLinkedSelection: item.state = model.linkedSelection ? .on : .off
        case .toggleRipple: item.state = model.rippleTrims ? .on : .off
        case .toggleTranscriptLane: item.state = model.showTranscript ? .on : .off
        case .toggleSafeMargins: item.state = model.showSafeMargins ? .on : .off
        case .toggleProxy: item.state = model.playback.useProxies ? .on : .off
        case .toolSelect, .toolBlade, .toolRippleTrim, .toolRoll, .toolSlip, .toolSlide:
            item.state = actions.tool(for: command) == model.tool ? .on : .off
        default: break
        }
        return actions.canPerform(command)
    }

    @objc func revealProject(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([model.fileURL])
    }

    /// Opens the archive sheet (see `ArchiveSheet.swift`).
    @objc func archiveProject(_ sender: Any?) {
        guard archiveSheet == nil, let window, window.attachedSheet == nil else { return }
        let sheetModel = ArchiveSheetModel(session: model.session, projectName: model.project.name)
        sheetModel.onFinished = { [weak self] result in
            guard let self else { return }
            self.model.refresh()
            self.model.show(.info, result.mode == .archive ? "Archived to \(result.folder)." : "\(self.model.fileName) is standalone now.")
        }
        let sheet = ArchiveSheetController(model: sheetModel, parent: window)
        sheet.onDismiss = { [weak self] in self?.archiveSheet = nil }
        archiveSheet = sheet
        sheet.present()
    }

    /// Opens the sheet that saves the selected clips as a segment in the
    /// shared library (see `SaveSegmentSheet.swift`).
    @objc func saveSelectionAsSegment(_ sender: Any?) {
        guard segmentSheet == nil, let window, window.attachedSheet == nil else { return }
        let ids = TimelineEdits.ordered(model.selection, in: model.project)
        guard !ids.isEmpty else {
            model.show(.info, "Select the clips to save as a segment first.")
            return
        }
        let host = AssetLibraryHost.shared
        let library = host.library?.sharedLibrary ?? SharedLibrary.locate()
        let sheetModel = SaveSegmentModel(project: model.project, folder: model.folder, clipIDs: ids, library: library)
        sheetModel.onSaved = { [weak self] stored in
            host.reloadSegments()
            var message = "Saved \(stored.name) to the shared library's Segments. It's in the Text tab under Segments."
            if let note = stored.segment.notes.first { message += " \(note)" }
            self?.model.show(.info, message)
        }
        let sheet = SaveSegmentSheetController(model: sheetModel, parent: window)
        sheet.onDismiss = { [weak self] in self?.segmentSheet = nil }
        segmentSheet = sheet
        sheet.present()
    }

    // MARK: - API

    /// Captures this window for the API's `screenshot`. It waits a moment
    /// first, so an edit the agent just made has drawn.
    func screenshotProvider() -> @Sendable () async throws -> Data {
        let capturer = WindowCapturer(window: window)
        return {
            try await Task.sleep(nanoseconds: 250_000_000)
            return try await capturer.png()
        }
    }

    // MARK: - Window

    /// Closing saves first; edits that won't save get a say.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        ProjectDocuments.confirmUnsaved([self], quitting: false)
    }

    func windowWillClose(_ notification: Notification) {
        saveTimeline()
        // An archive stops between chunks; running it again carries on.
        archiveSheet?.model.stop()
        router.uninstall()
        model.tearDown()
        let (project, revision) = model.session.coordinator.snapshot()
        model.session.close()
        // The project list shows this frame next time.
        ProjectIcons.shared.refresh(.closed, project: project, revision: revision, fileURL: model.fileURL, folder: model.folder, analysis: model.session.analysis)
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) {
        (window as? EditorWindow)?.layoutTrafficLights()
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    /// The playhead, zoom and scroll, for the next time this project opens.
    private func saveTimeline() {
        let scale = model.timeline.scale
        TimelinePlacement.save(TimelinePlacement.Saved(
            playhead: model.playback.time.seconds,
            pixelsPerSecond: scale.pixelsPerSecond,
            scrollSeconds: scale.scrollSeconds,
            verticalOffset: Double(model.timeline.verticalOffset)
        ), for: model.fileURL)
    }

    /// Carries on where the project's timeline was, instead of fitting it
    /// with the playhead at the start.
    private func restoreTimeline() {
        guard let saved = TimelinePlacement.saved(for: model.fileURL) else { return }
        model.timeline.fitPending = false
        model.timeline.scale = TimelineScale(pixelsPerSecond: saved.pixelsPerSecond, scrollSeconds: saved.scrollSeconds)
        model.timeline.verticalOffset = CGFloat(saved.verticalOffset)
        model.playback.seek(to: Time(seconds: saved.playhead).roundedToFrame(model.frameRate))
    }

    /// Remembers where the window is for the next one to open, but not a
    /// full screen or minimised window.
    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        WindowPlacement.save(window.frame, for: model.fileURL)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        (window as? EditorWindow)?.layoutTrafficLights()
        model.rescanMedia()
        // A font dropped into assets/font while Tandem was in the background.
        model.checkFonts()
        RelinkPrompt.windowBecameKey(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        // A held Z can't be released while another window has the keys.
        model.zoomKeyHeld = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        (window as? EditorWindow)?.layoutTrafficLights()
    }

    /// Renders the window's content to a PNG, for checking the layout and
    /// for agents. Uses `cacheDisplay`, so it works without screen
    /// recording permission.
    func screenshot(to url: URL) throws {
        guard let window else { throw EditError.invalid("no window to capture") }
        try WindowSnapshot.write(window, to: url)
    }
}

/// The project window. Its titlebar is as tall as the top bar, with the
/// traffic lights centred in it.
final class EditorWindow: NSWindow {
    func layoutTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let barHeight = Theme.Metrics.topBarHeight
        let frameHeight = container.superview?.frame.height ?? frame.height
        var containerFrame = container.frame
        if containerFrame.height != barHeight || containerFrame.maxY != frameHeight {
            containerFrame.size.height = barHeight
            containerFrame.origin.y = frameHeight - barHeight
            container.frame = containerFrame
        }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = standardWindowButton(type) else { continue }
            let origin = NSPoint(x: 16 + CGFloat(index) * 20, y: ((titlebar.frame.height - button.frame.height) / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }
}

extension String {
    /// "Move clip" to "move clip", for "Undo move clip".
    var lowercasedFirst: String {
        guard let first = first else { return self }
        // Keep words with capitals inside, like "PiP", as they are.
        let firstWord = prefix { $0 != " " }
        if firstWord.dropFirst().contains(where: \.isUppercase) { return self }
        return first.lowercased() + dropFirst()
    }
}

/// Holds the window weakly, so a screenshot request can't keep a closed
/// window alive.
@MainActor
private final class WindowCapturer {
    private weak var window: NSWindow?

    init(window: NSWindow?) {
        self.window = window
    }

    func png() throws -> Data {
        guard let window, window.isVisible else {
            throw ServiceError(.unavailable, "The project's window is closed.")
        }
        return try WindowSnapshot.pngData(of: window)
    }
}
