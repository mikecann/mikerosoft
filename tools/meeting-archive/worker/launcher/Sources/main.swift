import AppKit
import Darwin
import Foundation

private enum ArchiveAccess {
    static func verify(
        _ configuration: WorkerLauncherConfiguration,
        mode: LauncherServiceMode
    ) throws {
        try ArchivePathPreflight.verify(configuration, mode: mode)
        let path = configuration.archiveDirectory.path
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let message = String(cString: strerror(errno))
            throw LauncherFailure(
                "Meeting Archive Worker could not open \(path): \(message). " +
                "Choose the exact folder below to grant Removable Volumes access to this signed app."
            )
        }
        Darwin.close(descriptor)
    }
}

private final class ArchiveBookmarkStore {
    private let configuration: WorkerLauncherConfiguration

    init(configuration: WorkerLauncherConfiguration) {
        self.configuration = configuration
    }

    func save(_ selectedURL: URL) throws {
        if let message = configuration.selectionError(for: selectedURL) {
            throw LauncherFailure(message)
        }
        let data: Data
        do {
            data = try ArchiveBookmarkData.make(for: selectedURL)
        } catch {
            throw LauncherFailure("Could not save the archive selection: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(data, forKey: WorkerLauncherConfiguration.archiveBookmarkDefaultsKey)
        try verify(data)
    }

    func verifySaved() throws {
        guard let data = UserDefaults.standard.data(
            forKey: WorkerLauncherConfiguration.archiveBookmarkDefaultsKey
        ) else {
            throw LauncherFailure(
                "Archive access has not been granted yet. Choose exactly \(configuration.archiveDirectory.path) below."
            )
        }
        try verify(data)
    }

    private func verify(_ data: Data) throws {
        let bookmark: ResolvedArchiveBookmark
        do {
            bookmark = try ArchiveBookmarkData.resolve(data)
        } catch {
            throw LauncherFailure(
                "The saved archive selection could not be read. Open Meeting Archive Worker and choose the folder again."
            )
        }
        if let message = configuration.resolvedBookmarkError(for: bookmark.url) {
            throw LauncherFailure(message)
        }
        guard !bookmark.isStale else {
            throw LauncherFailure("The saved archive permission is stale. Choose the archive folder again.")
        }
    }
}

private struct LauncherFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
private final class WorkerLauncherDelegate: NSObject, NSApplicationDelegate {
    private let configuration = WorkerLauncherConfiguration()
    private lazy var archiveBookmark = ArchiveBookmarkStore(configuration: configuration)
    private var launchedWithServiceMode = false
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var child: Process?
    private var signalSources: [DispatchSourceSignal] = []
    private var shutdownStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalForwarding()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            launchedWithServiceMode = true
            NSApplication.shared.setActivationPolicy(.accessory)
            do {
                guard let mode = try configuration.requestedMode(arguments: arguments) else {
                    throw LauncherFailure("A service mode is required.")
                }
                try startService(mode)
            } catch {
                failHeadlessly(error)
            }
            return
        }

        do {
            _ = try configuration.requestedMode(arguments: arguments)
            showSetupWindow(message: setupMessage)
        } catch {
            showSetupWindow(message: error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        child == nil
    }

    private var setupMessage: String {
        "Choose \(configuration.archiveDirectory.path) to let Meeting Archive process and archive " +
        "recordings on CannMedia. When access is ready, close this window. The background service can then be enabled."
    }

    private func showSetupWindow(message: String) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window == nil {
            window = makeWindow()
        }
        statusLabel?.stringValue = message
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 250),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting Archive Worker"
        window.center()

        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let title = NSTextField(labelWithString: "CannMedia access")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 28, y: 190, width: 504, height: 28)
        content.addSubview(title)

        let status = NSTextField(wrappingLabelWithString: setupMessage)
        status.frame = NSRect(x: 28, y: 82, width: 504, height: 96)
        status.maximumNumberOfLines = 5
        content.addSubview(status)
        statusLabel = status

        let choose = NSButton(title: "Choose CannMedia Archive…", target: self, action: #selector(chooseArchive))
        choose.frame = NSRect(x: 28, y: 28, width: 220, height: 34)
        choose.bezelStyle = .rounded
        content.addSubview(choose)

        return window
    }

    @objc private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = "Grant Meeting Archive Worker access"
        panel.message = "Choose exactly \(configuration.archiveDirectory.path)."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes/CannMedia", isDirectory: true)
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        if let message = configuration.selectionError(for: selected) {
            statusLabel?.stringValue = message
            return
        }
        do {
            // The open occurs in the foreground, signed GUI process. macOS can
            // present scoped Removable Volumes consent here, and the child
            // process launched below inherits this app's responsibility.
            try archiveBookmark.save(selected)
            try ArchiveAccess.verify(configuration, mode: .worker)
            statusLabel?.stringValue = "Access is ready for \(configuration.archiveDirectory.path). You can close this app and enable the worker service."
        } catch {
            statusLabel?.stringValue = error.localizedDescription
        }
    }

    private func startService(_ mode: LauncherServiceMode) throws {
        guard child == nil else { return }
        try archiveBookmark.verifySaved()
        try ArchiveAccess.verify(configuration, mode: mode)
        let process = Process()
        process.executableURL = configuration.serviceExecutable
        process.arguments = configuration.serviceArguments(for: mode)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.child = nil
                Darwin.exit(finished.terminationStatus)
            }
        }
        try process.run()
        child = process
    }

    private func failHeadlessly(_ error: Error) -> Never {
        let message = "Meeting Archive Worker launcher: \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
        Darwin.exit(EX_CONFIG)
    }

    private func installSignalForwarding() {
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.stopChildAndExit()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func stopChildAndExit() {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        if let child {
            ChildProcessShutdown.stop(child)
        }
        Darwin.exit(EXIT_SUCCESS)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if launchedWithServiceMode, let child {
            ChildProcessShutdown.stop(child)
        }
        return .terminateNow
    }
}

@main
private enum MeetingArchiveWorkerLauncher {
    static func main() {
        Darwin.signal(SIGTERM, SIG_IGN)
        Darwin.signal(SIGINT, SIG_IGN)
        let application = NSApplication.shared
        let delegate = WorkerLauncherDelegate()
        application.delegate = delegate
        application.run()
    }
}
