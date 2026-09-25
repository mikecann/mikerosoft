import AppKit
import SwiftUI
import TandemAPI
import TandemCore

/// One project window: the Graphite layout around an `EditorModel`.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, EditorCommandHandling {
    let model: EditorModel
    let actions: EditorActions
    private let router: KeyboardRouter
    /// Called once the window has closed and the session is released.
    var onClose: ((ProjectWindowController) -> Void)?

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
        window.setFrameAutosaveName("Tandem project")
        super.init(window: window)
        window.delegate = self
        actions.controller = self
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

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        router.uninstall()
        model.tearDown()
        model.session.close()
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) {
        (window as? EditorWindow)?.layoutTrafficLights()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        (window as? EditorWindow)?.layoutTrafficLights()
        model.rescanMedia()
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

/// The project window. Its titlebar is as tall as the design's 48 pt top
/// bar, with the traffic lights centred in it.
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
