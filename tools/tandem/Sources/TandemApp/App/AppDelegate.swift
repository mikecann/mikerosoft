import AppKit
import TandemCore

/// Starts the app: menus, the keymap, projects from the command line,
/// Finder and `open -a`, and the `tandem://` URL scheme.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, EditorCommandHandling {
    private let documents = ProjectDocuments.shared
    private var launched = false
    private var pendingURLs: [URL] = []
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        documents.keymap = KeymapStore.load(report: { message in
            NSLog("Tandem keymap: %@", message)
        })
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.build(keymap: documents.keymap, recentDelegate: documents)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        quitCleanlyOnSIGTERM()
        MainThreadMeter.install()
        // Opens the asset library in the background, adding the starter
        // emoji, icons and logos the first time.
        AssetLibraryHost.shared.open()
        NSApp.setActivationPolicy(.regular)
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let fromCommandLine = arguments.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            .filter { $0.pathExtension == ProjectFile.fileExtension }
        let urls = pendingURLs + fromCommandLine
        pendingURLs = []
        handle(urls)
        if documents.windows.isEmpty && !documents.isOpening { documents.showWelcome() }
        // No activate() here: Finder, the Dock and `open` bring the app
        // forward themselves, and `open -g` (agents, scripts) must leave
        // whatever Mike is using in front.
        scheduleLaunchScreenshot()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingURLs += urls
            return
        }
        handle(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.showWelcome() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Edits that won't save get a say first, except when a signal asked
        // (an alert would hang `kill`; the journal keeps what it can).
        if !quittingOnSignal, !ProjectDocuments.confirmUnsaved(documents.windows, quitting: true) {
            return .terminateCancel
        }
        documents.isTerminating = true
        documents.closeAll()
        // Closing makes each project's icon; give them a moment to land.
        // A run loop timer, not a task: if quitting started inside a main
        // queue block, main actor work can't run until it's over, and the
        // timer still ends the wait.
        guard ProjectIcons.shared.isBusy else { return .terminateNow }
        let deadline = Date().addingTimeInterval(3)
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !ProjectIcons.shared.isBusy || Date() >= deadline else { return }
                timer.invalidate()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    /// Set when SIGTERM asked Tandem to quit.
    private var quittingOnSignal = false

    /// `kill` (and `kill.sh`) quits like Cmd-Q: projects save, the API
    /// stops and locks are released, instead of the process just ending.
    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.quittingOnSignal = true
                // From the run loop, not from inside this main queue
                // block, so work queued on the main actor can still run
                // while Tandem quits.
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
        }
        source.resume()
        terminationSignal = source
    }

    // MARK: - Opening and URL commands

    private func handle(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                documents.open(url)
            } else if let command = AppURLCommand.parse(url) {
                run(command)
            } else {
                NSLog("Tandem: ignored %@", url.absoluteString)
            }
        }
    }

    private func run(_ command: AppURLCommand) {
        let front = documents.frontmost
        switch command {
        case .screenshot(let out):
            // Give SwiftUI a moment to settle after any command that came
            // just before.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated {
                    let window = ProjectDocuments.shared.frontmost?.window ?? NSApp.windows.first { $0.isVisible }
                    guard let window else { return NSLog("Tandem: no window to capture") }
                    do {
                        try WindowSnapshot.write(window, to: URL(fileURLWithPath: out))
                    } catch {
                        NSLog("Tandem: screenshot failed: %@", error.localizedDescription)
                    }
                }
            }
        case .open(let path):
            documents.open(URL(fileURLWithPath: path))
        case .command(let editorCommand):
            if let front {
                front.actions.perform(editorCommand)
            } else if editorCommand == .newProject || editorCommand == .openProject {
                performCommand(editorCommand)
            }
        case .seek(let time):
            front?.model.playback.pause()
            front?.model.playback.seek(to: time)
        case .select(let ids):
            front?.model.selection = Set(ids)
            front?.model.focusedClipID = ids.first
        case .panels(let library, let inspector, let sheet):
            if let library { front?.model.libraryTab = library }
            if let inspector { front?.model.inspectorTab = inspector }
            if let sheet { front?.model.showExportSheet = sheet }
        case .zoom(let pps, let scroll):
            guard let timeline = front?.model.timeline else { return }
            timeline.fitPending = false
            if let pps { timeline.scale.pixelsPerSecond = pps }
            if let scroll { timeline.scale.scrollSeconds = scroll }
        case .tool(let tool):
            front?.model.tool = tool
        case .inOut(let start, let end):
            front?.model.inPoint = start
            front?.model.outPoint = end
        case .simulate(let gesture):
            guard let front, let window = front.window else { return }
            if gesture.heldKey == "z" { front.model.zoomKeyHeld = true }
            InputSimulator.run(gesture, in: window) {
                if gesture.heldKey == "z" { front.model.zoomKeyHeld = false }
            }
        case .windowSize(let width, let height):
            guard let window = front?.window ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            let size = NSSize(width: max(width, window.contentMinSize.width), height: max(height, window.contentMinSize.height))
            window.setContentSize(size)
        case .windowOrder(let toFront):
            // Without activating the app, so whatever Mike is typing into
            // keeps the keys.
            guard let window = front?.window ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            if toFront { window.orderFrontRegardless() } else { window.orderBack(nil) }
        case .debug(let out, let resetTimings):
            guard let window = front?.window ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            try? WindowSnapshot.describe(window).write(toFile: out, atomically: true, encoding: .utf8)
            if resetTimings { DrawTiming.reset() }
        case .newProject(let folder):
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
                return NSLog("Tandem: no folder at %@", folder)
            }
            documents.createProject(inFolder: URL(fileURLWithPath: folder, isDirectory: true))
        case .assets(let section, let search, let scope, let online):
            let host = AssetLibraryHost.shared
            if let model = front?.model { host.show(section, in: model) }
            if let search { host.update(section) { $0.text = search } }
            if let scope { host.update(section) { $0.scope = scope } }
            if online { host.searchOnline(section) }
        case .saveVersion(let out):
            // Links never replace a file; Save As in the app asks first.
            guard let front, !FileManager.default.fileExists(atPath: out) else {
                return NSLog("Tandem: not saving a version to %@", out)
            }
            documents.saveVersion(of: front.model, to: URL(fileURLWithPath: out))
        }
    }

    /// `TANDEM_SCREENSHOT=<path>` writes a screenshot of the first window a
    /// couple of seconds after launch; `TANDEM_SCREENSHOT_QUIT=1` quits after.
    private func scheduleLaunchScreenshot() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TANDEM_SCREENSHOT"], !path.isEmpty else { return }
        let delay = Double(environment["TANDEM_SCREENSHOT_DELAY"] ?? "") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                self.run(.screenshot(out: path))
                if environment["TANDEM_SCREENSHOT_QUIT"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                }
            }
        }
    }

    // MARK: - Commands without a project window

    @objc func performEditorCommand(_ sender: Any?) {
        guard let command = MainMenu.command(of: sender) else { return }
        performCommand(command)
    }

    private func performCommand(_ command: EditorCommand) {
        switch command {
        case .newProject: documents.newProject()
        case .openProject: documents.openPanel()
        default: NSSound.beep()
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = MainMenu.command(of: item) else { return true }
        return command == .newProject || command == .openProject
    }

    @objc func showKeymapFile(_ sender: Any?) {
        let url = KeymapStore.userKeymapURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? KeymapStore.writeTemplate(to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
