import AppKit
import TandemAPI
import TandemAssets
import TandemCore
import TandemMedia

/// A project that opens with media files missing (it came from another Mac,
/// or its folder was tidied by hand) gets them looked for: files moved
/// within the project folder, or in this Mac's shared library (a sticker
/// or sound the project used from the library on another Mac), are
/// relinked straight away, and for the rest Mike is asked for a folder to
/// search. A file is only taken when it's the same file (`MediaRelinker`,
/// the same as `tandem relink`).
///
/// The question waits until the window is in front: a project opened in
/// the background (`open -g`, as scripts and agents do) isn't blocked by a
/// sheet nobody is looking at.
@MainActor
enum RelinkPrompt {
    /// Windows with missing media to ask about when they're next in front.
    private static var waiting = Set<ObjectIdentifier>()

    static func checkAfterOpening(_ controller: ProjectWindowController) {
        let session = controller.model.session
        let folder = session.folder
        let missing = MediaRelinker.missing(in: session.coordinator.project, folder: folder)
        guard !missing.isEmpty else { return }
        let shared = (AssetLibraryHost.shared.library?.sharedLibrary ?? SharedLibrary.locate())
        let fallback = shared.exists ? [shared.root] : []
        Task { @MainActor [weak controller] in
            let found = await search(missing, in: [folder.root], then: fallback, folder: folder)
            guard let controller else { return }
            let relinked = apply(found, to: controller, author: ActivityLog.systemAuthor)
            if relinked > 0 {
                controller.model.show(.info, "Found \(files(relinked)) that had moved in the project folder or are in the shared library, and relinked \(relinked == 1 ? "it" : "them").")
            }
            let still = MediaRelinker.missing(in: session.coordinator.project, folder: folder)
            guard !still.isEmpty else { return }
            if NSApp.isActive, controller.window?.isKeyWindow == true {
                ask(about: still, controller: controller)
            } else {
                waiting.insert(ObjectIdentifier(controller))
            }
        }
    }

    /// Asks about missing media held back until the window came forward.
    static func windowBecameKey(_ controller: ProjectWindowController) {
        guard waiting.remove(ObjectIdentifier(controller)) != nil else { return }
        let still = MediaRelinker.missing(in: controller.model.session.coordinator.project, folder: controller.model.session.folder)
        if !still.isEmpty { ask(about: still, controller: controller) }
    }

    /// Says which files are missing and offers to search a folder for them.
    static func ask(about missing: [MediaItem], controller: ProjectWindowController) {
        guard let window = controller.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "\(files(missing.count)) \(missing.count == 1 ? "is" : "are") missing"
        var names = missing.prefix(6).map { "  \($0.path)" }
        if missing.count > 6 { names.append("  and \(missing.count - 6) more") }
        alert.informativeText = """
        Tandem couldn't find \(missing.count == 1 ? "it" : "these") in the project folder or the shared library:
        \(names.joined(separator: "\n"))

        If you know where \(missing.count == 1 ? "it is" : "they are"), choose a folder to search. Its subfolders are searched too, and a file is only used when it's the same file. Clips using a missing file show nothing until it's found.
        """
        alert.addButton(withTitle: "Search a folder…")
        alert.addButton(withTitle: "Not now")
        alert.beginSheetModal(for: window) { [weak controller] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let controller else { return }
                chooseFolder(for: missing, controller: controller)
            }
        }
    }

    private static func chooseFolder(for missing: [MediaItem], controller: ProjectWindowController) {
        guard let window = controller.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Search"
        panel.message = "Choose a folder to look for the missing files in."
        panel.beginSheetModal(for: window) { [weak controller] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let controller else { return }
                Task { @MainActor [weak controller] in
                    let session = controller?.model.session
                    guard let session else { return }
                    let found = await search(missing, in: [url], folder: session.folder)
                    guard let controller else { return }
                    let relinked = apply(found, to: controller, author: "user")
                    if relinked > 0 {
                        controller.model.show(.info, "Relinked \(files(relinked)) from \(url.lastPathComponent).")
                    } else {
                        controller.model.show(.warning, "None of the missing files were in \(url.lastPathComponent).")
                    }
                    let still = MediaRelinker.missing(in: session.coordinator.project, folder: session.folder)
                    // Found some: offer another folder for the rest.
                    if !still.isEmpty, relinked > 0 { ask(about: still, controller: controller) }
                }
            }
        }
    }

    private static func search(_ items: [MediaItem], in folders: [URL], then fallback: [URL] = [], folder: ProjectFolder) async -> [MediaRelinker.Match] {
        (try? await ProjectArchiver.onBackgroundThread { MediaRelinker.search(for: items, in: folders, then: fallback, folder: folder).found }) ?? []
    }

    /// Points the project at what was found, as one undo step. Returns how
    /// many files it relinked.
    private static func apply(_ found: [MediaRelinker.Match], to controller: ProjectWindowController, author: String) -> Int {
        guard !found.isEmpty else { return 0 }
        let session = controller.model.session
        for attempt in 1...5 {
            let (project, revision) = session.coordinator.snapshot()
            // Something else may have found a file meanwhile.
            let still = found.filter { project.media($0.mediaID)?.path == $0.from }
            guard !still.isEmpty else { return 0 }
            let label = "Relink \(files(still.count))"
            do {
                try session.coordinator.apply(EditBatch(label: label, author: author, commands: MediaRelinker.commands(for: still), expectedRevision: revision))
                controller.model.refresh()
                return still.count
            } catch EditError.staleRevision where attempt < 5 {
                continue
            } catch {
                controller.model.show(.error, "Couldn't relink: \(EditorModel.describe(error))")
                return 0
            }
        }
        return 0
    }

    private static func files(_ n: Int) -> String {
        n == 1 ? "1 media file" : "\(n) media files"
    }
}
