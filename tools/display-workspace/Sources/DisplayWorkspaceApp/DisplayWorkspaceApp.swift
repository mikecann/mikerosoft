import AppKit
import CoreGraphics
import Darwin
import Foundation
import OSLog
import DisplayWorkspaceCore
import DisplayWorkspaceMac

private let logger = Logger(
    subsystem: "com.mikerosoft.display-workspace",
    category: "app"
)

@main
struct DisplayWorkspaceMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
            return
        }
        if let profileName = argumentValue(after: "--save-profile") {
            do {
                let profile = try WorkspaceApplicationService.makeDefault()
                    .saveCurrentWorkspace(name: profileName)
                print("Saved \(profile.name): \(profile.displayIDs.count) displays, \(profile.windowLayout.windows.count) windows")
            } catch {
                print("FAIL \(error.localizedDescription)")
                Darwin.exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--restore-matching") {
            do {
                let result = try WorkspaceApplicationService.makeDefault()
                    .restoreMatchingWorkspace()
                print(result)
            } catch {
                print("FAIL \(error.localizedDescription)")
                Darwin.exit(1)
            }
            return
        }
        guard let instanceLock = SingleInstanceLock.acquire() else {
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(instanceLock) {}
    }
}

private func argumentValue(after option: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: option),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

private final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() -> SingleInstanceLock? {
        let path = "/tmp/com.mikerosoft.display-workspace.\(getuid()).lock"
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return SingleInstanceLock(fileDescriptor: descriptor)
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
    }
}

private enum Diagnostics {
    static func run() {
        let betterDisplayURL = URL(
            fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
        )
        guard FileManager.default.isExecutableFile(atPath: betterDisplayURL.path) else {
            print("FAIL BetterDisplay executable not found at \(betterDisplayURL.path)")
            return
        }

        do {
            let betterDisplay = BetterDisplayController(executableURL: betterDisplayURL)
            let ids = try betterDisplay.connectedDisplayIDs()
            let configuration = try betterDisplay.captureConfiguration()
            print("OK BetterDisplay connected")
            print("Active displays: \(ids.joined(separator: ", "))")
            for display in configuration.displays {
                let refresh = display.refreshRate.map { "\($0) Hz" } ?? "dynamic"
                print(
                    "  \(display.name): \(display.resolution.width)x\(display.resolution.height), "
                        + "\(refresh), origin \(Int(display.origin.x))x\(Int(display.origin.y))"
                )
            }

            let trusted = AccessibilityWindowSystem.isTrusted(prompt: false)
            print("Accessibility: \(trusted ? "granted" : "permission required")")
            if trusted {
                let backend = try SkyLightWindowServerSpaceBackend()
                let spaces = MacSpaceSystem(backend: backend, identities: betterDisplay)
                let currentSpaces = try spaces.currentSpaces()
                print("Active user Desktops: \(currentSpaces.count)")
                let windows = try AccessibilityWindowSystem(spaceLocator: spaces).currentWindows()
                print("Visible/accessibility windows: \(windows.count)")
                print("Windows with Desktop identity: \(windows.filter { $0.spaceID != nil }.count)")
            }
        } catch {
            print("FAIL \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let service: WorkspaceApplicationService
    private var displayMonitor: DisplayReconfigurationMonitor?
    private var status = "Ready"
    private var suppressAutomaticRestoreUntil = Date.distantPast

    override init() {
        service = WorkspaceApplicationService.makeDefault()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.3.group",
                accessibilityDescription: "Display Workspace"
            )
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !AccessibilityWindowSystem.isTrusted(prompt: false) {
            status = "Accessibility permission required"
        }

        let monitor = DisplayReconfigurationMonitor { [weak self] in
            self?.restoreAutomatically()
        }
        monitor.start()
        displayMonitor = monitor

        // Restore after login too, once BetterDisplay has finished discovering devices.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.restoreAutomatically()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayMonitor?.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let heading = NSMenuItem(title: "Display Workspace", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Save Current Setup…", action: #selector(saveCurrentSetup), keyEquivalent: "s")
            .target = self
        menu.addItem(withTitle: "Restore Matching Setup", action: #selector(restoreMatchingSetup), keyEquivalent: "r")
            .target = self

        do {
            let profiles = try service.profiles()
            if !profiles.isEmpty {
                let profilesItem = NSMenuItem(title: "Saved Setups", action: nil, keyEquivalent: "")
                let profilesMenu = NSMenu()
                for profile in profiles {
                    let item = NSMenuItem(
                        title: "\(profile.name) (\(profile.displayIDs.count) displays, \(profile.windowLayout.windows.count) windows)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    item.isEnabled = false
                    profilesMenu.addItem(item)
                }
                profilesItem.submenu = profilesMenu
                menu.addItem(profilesItem)
            }
        } catch {
            logger.error("Could not load profiles: \(error.localizedDescription, privacy: .public)")
        }

        menu.addItem(.separator())
        if !AccessibilityWindowSystem.isTrusted(prompt: false) {
            menu.addItem(
                withTitle: "Grant Accessibility Permission…",
                action: #selector(requestAccessibilityPermission),
                keyEquivalent: ""
            ).target = self
        }
        menu.addItem(
            withTitle: "Open Profiles Folder",
            action: #selector(openProfilesFolder),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func saveCurrentSetup() {
        guard AccessibilityWindowSystem.isTrusted(prompt: true) else {
            status = "Grant Accessibility permission, then try again"
            return
        }

        do {
            let suggestedName = try service.connectedDisplayIDs().count > 1 ? "Docked" : "Laptop"
            let alert = NSAlert()
            alert.messageText = "Save Current Setup"
            alert.informativeText = "Arrange the displays and windows first. Saving the same name updates that setup."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let input = NSTextField(string: suggestedName)
            input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = input
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }

            status = "Saving \(name)…"
            let profile = try service.saveCurrentWorkspace(name: name)
            status = "Saved \(profile.name): \(profile.windowLayout.windows.count) windows"
            logger.info("Saved profile \(profile.name, privacy: .public)")
        } catch {
            present(error: error, action: "save the setup")
        }
    }

    @objc private func restoreMatchingSetup() {
        restore(manual: true)
    }

    private func restoreAutomatically() {
        guard Date() >= suppressAutomaticRestoreUntil else { return }
        restore(manual: false)
    }

    private func restore(manual: Bool) {
        guard AccessibilityWindowSystem.isTrusted(prompt: manual) else {
            status = "Accessibility permission required"
            return
        }

        do {
            suppressAutomaticRestoreUntil = Date().addingTimeInterval(10)
            status = manual ? "Restoring…" : "Displays changed, restoring…"
            switch try service.restoreMatchingWorkspace() {
            case let .restored(profileName):
                status = "Restored \(profileName)"
                logger.info("Restored profile \(profileName, privacy: .public)")
            case .noMatchingProfile:
                status = "No saved setup matches these displays"
            }
        } catch {
            present(error: error, action: "restore the setup", showAlert: manual)
        }
    }

    @objc private func requestAccessibilityPermission() {
        _ = AccessibilityWindowSystem.isTrusted(prompt: true)
    }

    @objc private func openProfilesFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([service.profileFileURL])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func present(error: Error, action: String, showAlert: Bool = true) {
        status = "Could not \(action): \(error.localizedDescription)"
        logger.error("Could not \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
        guard showAlert else { return }
        let alert = NSAlert(error: error)
        alert.messageText = "Display Workspace could not \(action)"
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private final class WorkspaceApplicationService {
    private let repository: JSONProfileRepository
    private let betterDisplay: BetterDisplayController
    private let windows: MacWindowController

    init(
        repository: JSONProfileRepository,
        betterDisplay: BetterDisplayController,
        windows: MacWindowController
    ) {
        self.repository = repository
        self.betterDisplay = betterDisplay
        self.windows = windows
    }

    static func makeDefault() -> WorkspaceApplicationService {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Display Workspace", isDirectory: true)
        let repository = JSONProfileRepository(
            fileURL: supportDirectory.appendingPathComponent("profiles.json")
        )
        let betterDisplay = BetterDisplayController(
            executableURL: URL(
                fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
            )
        )
        let spaceSystem: any SpaceSystem
        let spaceLocator: (any WindowSpaceLocating)?
        if let backend = try? SkyLightWindowServerSpaceBackend() {
            let macSpaces = MacSpaceSystem(backend: backend, identities: betterDisplay)
            spaceSystem = macSpaces
            spaceLocator = macSpaces
        } else {
            spaceSystem = NoopSpaceSystem()
            spaceLocator = nil
        }
        let windows = MacWindowController(
            windowSystem: AccessibilityWindowSystem(spaceLocator: spaceLocator),
            displays: betterDisplay,
            spaces: spaceSystem
        )
        return WorkspaceApplicationService(
            repository: repository,
            betterDisplay: betterDisplay,
            windows: windows
        )
    }

    var profileFileURL: URL {
        repository.fileURL
    }

    func profiles() throws -> [WorkspaceProfile] {
        try repository.loadProfiles()
    }

    func connectedDisplayIDs() throws -> [String] {
        try betterDisplay.connectedDisplayIDs()
    }

    func saveCurrentWorkspace(name: String) throws -> WorkspaceProfile {
        try WorkspaceRecorder(
            profiles: repository,
            displays: betterDisplay,
            windows: windows
        ).saveCurrentWorkspace(
            name: name,
            connectedDisplayIDs: betterDisplay.connectedDisplayIDs()
        )
    }

    func restoreMatchingWorkspace() throws -> RestoreResult {
        try WorkspaceRestorer(
            profiles: repository,
            displays: betterDisplay,
            settler: FixedDisplaySettler(),
            windows: windows
        ).restore(connectedDisplayIDs: betterDisplay.connectedDisplayIDs())
    }
}

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
    let monitor = Unmanaged<DisplayReconfigurationMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    monitor.displayDidChange()
}

private final class DisplayReconfigurationMonitor {
    private let handler: () -> Void
    private var timer: Timer?
    private var isStarted = false

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() {
        guard !isStarted else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            pointer
        ) == .success else {
            logger.error("Could not register display reconfiguration callback")
            return
        }
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, pointer)
        timer?.invalidate()
        isStarted = false
    }

    fileprivate func displayDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                self?.handler()
            }
        }
    }

    deinit {
        stop()
    }
}
