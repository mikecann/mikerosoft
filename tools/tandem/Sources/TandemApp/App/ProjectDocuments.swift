import AppKit
import SwiftUI
import TandemAPI
import TandemCore
import UniformTypeIdentifiers

/// Opens, creates and versions projects, and keeps the recent list.
@MainActor
final class ProjectDocuments: NSObject, NSMenuDelegate {
    static let shared = ProjectDocuments()

    private(set) var windows: [ProjectWindowController] = []
    private(set) var recent = RecentProjects.load()
    var keymap: Keymap = .empty {
        didSet { for controller in windows { controller.keymap = keymap } }
    }
    /// Set while quitting, so closing the last window doesn't bring up the
    /// welcome window.
    var isTerminating = false
    private var welcome: WelcomeWindowController?

    static let tandemType = UTType(filenameExtension: ProjectFile.fileExtension) ?? .json

    // MARK: - Opening

    /// Projects waiting for a CLI command or `tandem serve` to let go.
    private var opening: Set<URL> = []
    /// True while a project is still on its way, so launch doesn't show the
    /// welcome window in the meantime.
    var isOpening: Bool { !opening.isEmpty }

    /// Opens a project, or brings its window forward if it's already open.
    /// Returns nil if it failed, or if it's waiting for another process to
    /// let go, in which case the window comes up when it does.
    @discardableResult
    func open(_ url: URL, frame: NSRect? = nil) -> ProjectWindowController? {
        let url = url.standardizedFileURL
        if let existing = windows.first(where: { $0.model.fileURL.standardizedFileURL == url }) {
            existing.showWindow(nil)
            return existing
        }
        do {
            return opened(try ProjectSession.open(url, owner: .app), url: url, frame: frame)
        } catch {
            if Self.isLocked(error) {
                openWhenFree(url, frame: frame)
            } else {
                failedToOpen(url, error)
            }
            return nil
        }
    }

    /// A CLI command has the project for a moment, or `tandem serve` has
    /// it open: wait a few seconds, asking the server to hand it over.
    private func openWhenFree(_ url: URL, frame: NSRect?) {
        guard opening.insert(url).inserted else { return }
        Task { @MainActor in
            do {
                let session = try await ProjectSession.open(url, owner: .app, waitingUpTo: 5)
                self.opening.remove(url)
                self.opened(session, url: url, frame: frame)
            } catch {
                self.opening.remove(url)
                self.failedToOpen(url, error)
            }
        }
    }

    @discardableResult
    private func opened(_ session: ProjectSession, url: URL, frame: NSRect?) -> ProjectWindowController {
        let controller = present(EditorModel(session: session), frame: frame)
        noteRecent(url)
        // Pick up files added to the folder while Tandem was closed.
        controller.model.rescanMedia(ifOlderThan: 0)
        return controller
    }

    private func failedToOpen(_ url: URL, _ error: Error) {
        if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileReadNoSuchFileError {
            recent.remove(url.path)
            recent.save()
        }
        alert("Couldn't open \(url.lastPathComponent)", EditorModel.describe(error))
        if windows.isEmpty && opening.isEmpty && !isTerminating { showWelcome() }
    }

    private static func isLocked(_ error: Error) -> Bool {
        guard let edit = error as? EditError, case .locked = edit else { return false }
        return true
    }

    private func present(_ model: EditorModel, frame: NSRect?) -> ProjectWindowController {
        let controller = ProjectWindowController(model: model, keymap: keymap, frame: frame)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            guard let self, self.windows.isEmpty, !self.isTerminating else { return }
            self.showWelcome()
        }
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        welcome?.close()
        welcome = nil
        model.startAPI(screenshot: controller.screenshotProvider())
        return controller
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.tandemType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a Tandem project"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    /// New project: pick the video's folder and a project named after it is
    /// made inside, with Mike's standard tracks, and the folder is scanned.
    func newProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Create project"
        panel.message = "Choose the video's folder. The project is saved inside it."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        createProject(inFolder: folder)
    }

    /// Makes `<folder>/<folder name>.tandem` and opens it, or opens the
    /// project that's already there.
    @discardableResult
    func createProject(inFolder folder: URL) -> ProjectWindowController? {
        let name = folder.lastPathComponent
        let url = folder.appendingPathComponent("\(name).\(ProjectFile.fileExtension)")
        if FileManager.default.fileExists(atPath: url.path) {
            return open(url)
        }
        do {
            let session = try ProjectSession.create(at: url, name: Self.projectName(forFolder: name), owner: .app)
            return opened(session, url: url, frame: nil)
        } catch {
            alert("Couldn't create the project", EditorModel.describe(error))
            return nil
        }
    }

    /// `decision-models` becomes "Decision models".
    nonisolated static func projectName(forFolder folder: String) -> String {
        let words = folder.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = words.first else { return folder }
        return first.uppercased() + words.dropFirst()
    }

    /// Save As for versions: writes the project to `Name v2.tandem` (or a
    /// name you pick) and continues editing the new file.
    func saveVersion(of model: EditorModel) {
        let folder = model.fileURL.deletingLastPathComponent()
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.tandemType]
        panel.directoryURL = folder
        panel.nameFieldStringValue = VersionNaming.nextName(after: model.fileName, existing: existing)
        panel.message = "Save a new version. You keep editing the new file; the old one stays as it is now."
        guard panel.runModal() == .OK, let target = panel.url else { return }
        saveVersion(of: model, to: target)
    }

    /// Writes the project to `target` and swaps the window over to it. The
    /// old file is saved as it stands and closed.
    @discardableResult
    func saveVersion(of model: EditorModel, to target: URL) -> ProjectWindowController? {
        let target = target.standardizedFileURL
        guard target != model.fileURL.standardizedFileURL else { return nil }
        if windows.contains(where: { $0.model.fileURL.standardizedFileURL == target }) {
            alert("Couldn't save the version", "\(target.lastPathComponent) is open in another window.")
            return nil
        }
        do {
            try model.session.save()
            let (project, revision) = model.session.coordinator.snapshot()
            let moved = VersionNaming.relocated(project, from: model.fileURL.deletingLastPathComponent(), to: target.deletingLastPathComponent())
            // A file being replaced may have left a journal behind; replaying
            // it over the new version would bring back its old edits.
            ProjectJournal.forProject(at: target).truncate()
            try ProjectFile.save(moved, revision: revision, to: target)
        } catch {
            alert("Couldn't save the version", EditorModel.describe(error))
            return nil
        }
        // Open the new file before closing the old one, so the welcome
        // window doesn't flash up in between, and a failed open leaves the
        // old window where it was.
        let old = windows.first { $0.model === model }
        guard let controller = open(target, frame: old?.window?.frame) else { return nil }
        old?.close()
        controller.model.show(.info, "Now editing \(target.lastPathComponent).")
        return controller
    }

    // MARK: - Recent projects

    private func noteRecent(_ url: URL) {
        recent.add(url.path)
        recent.save()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = recent.existing()
        for url in urls {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if urls.isEmpty {
            menu.addItem(withTitle: "No recent projects", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    @objc private func clearRecent(_ sender: Any?) {
        recent = RecentProjects()
        recent.save()
        welcome?.refresh()
    }

    // MARK: - Welcome

    func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindowController(documents: self)
        }
        welcome?.refresh()
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    func closeAll() {
        for controller in windows { controller.close() }
    }

    var frontmost: ProjectWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.first { $0.window?.isMainWindow == true } ?? windows.last
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
