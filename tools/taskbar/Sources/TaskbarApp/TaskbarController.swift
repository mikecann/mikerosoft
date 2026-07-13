import AppKit
import QuartzCore

final class TaskbarPanel {
    let screenID: UInt32
    let panel: NSPanel
    let containerView: TaskbarContainerView
    let view: TaskbarView
    private var screen: ScreenInfo
    private var values: TaskbarSettingValues
    private var isShown = true

    init(screen: ScreenInfo, values: TaskbarSettingValues, controller: TaskbarController) {
        screenID = screen.id
        self.screen = screen
        self.values = values
        let height = CGFloat(values.taskbarHeight)

        let frame = NSRect(
            x: screen.appKitFrame.minX,
            y: screen.appKitFrame.minY,
            width: screen.appKitFrame.width,
            height: height
        )

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "mikerosoft taskbar"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        view = TaskbarView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        containerView = TaskbarContainerView(frame: view.frame, taskbarView: view)
        view.settings = values
        view.onActivate = { [weak controller] item in
            controller?.activate(item: item)
        }
        view.onMenu = { [weak controller, screenID] in
            controller?.makeSettingsMenu(screenID: screenID) ?? NSMenu()
        }
        view.onItemMenu = { [weak controller, screenID] item in
            controller?.makeItemMenu(for: item, screenID: screenID)
        }
        view.onMovePinnedItem = { [weak controller, screenID] item, target in
            controller?.movePinnedItem(item, before: target, screenID: screenID)
        }
        panel.contentView = containerView
    }

    func update(screen: ScreenInfo, items: [TaskbarItem], values: TaskbarSettingValues) {
        self.screen = screen
        self.values = values

        guard values.isVisible else {
            panel.orderOut(nil)
            return
        }

        let height = CGFloat(values.taskbarHeight)
        let frame = NSRect(
            x: screen.appKitFrame.minX,
            y: screen.appKitFrame.minY,
            width: screen.appKitFrame.width,
            height: height
        )
        containerView.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        containerView.update(items: items, settings: values)
        panel.orderFrontRegardless()

        if values.autoHide {
            updateAutoHide(mouseLocation: NSEvent.mouseLocation, animated: false)
        } else {
            setShown(true, animated: false)
        }
    }

    func updateAutoHide(mouseLocation: NSPoint, animated: Bool) {
        guard values.isVisible, values.autoHide else { return }
        setShown(shouldReveal(mouseLocation: mouseLocation), animated: animated)
    }

    func close() {
        panel.orderOut(nil)
    }

    private func shouldReveal(mouseLocation: NSPoint) -> Bool {
        guard screen.appKitFrame.contains(mouseLocation) else { return false }
        let revealHeight = isShown ? CGFloat(values.taskbarHeight) + 8 : 6
        return mouseLocation.y <= screen.appKitFrame.minY + revealHeight
    }

    private func setShown(_ shown: Bool, animated: Bool) {
        let targetFrame = frame(shown: shown)
        guard panel.frame != targetFrame else { return }

        isShown = shown
        if !animated || values.revealAnimation == .instant || values.revealAnimationDuration <= 0 {
            panel.setFrame(targetFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = values.revealAnimationDuration
            context.timingFunction = timingFunction(for: values.revealAnimation)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func frame(shown: Bool) -> NSRect {
        let height = CGFloat(values.taskbarHeight)
        let visibleStrip: CGFloat = 3
        return NSRect(
            x: screen.appKitFrame.minX,
            y: shown ? screen.appKitFrame.minY : screen.appKitFrame.minY - height + visibleStrip,
            width: screen.appKitFrame.width,
            height: height
        )
    }

    private func timingFunction(for animation: RevealAnimation) -> CAMediaTimingFunction? {
        switch animation {
        case .instant:
            return nil
        case .linear:
            return CAMediaTimingFunction(name: .linear)
        case .ease:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }
}

final class TaskbarController: NSObject {
    private let settings = TaskbarSettings()
    private let windowAvoider = WindowAvoider()
    private var panels: [UInt32: TaskbarPanel] = [:]
    private var timer: Timer?
    private var autoHideTimer: Timer?
    private var settingsWindowController: SettingsWindowController?
    private var menuItemContext: (screenID: UInt32, item: TaskbarItem)?
    private var menuScreenContext: UInt32?
    private let commandFileURL = URL(fileURLWithPath: "/tmp/mikerosoft-taskbar-command")

    func start() {
        settings.onChange = { [weak self] in
            self?.syncStartAtLogin()
            self?.refresh()
        }
        syncStartAtLogin()
        log("screens=\(collectScreens().map { "\($0.name):\($0.appKitFrame)" }.joined(separator: " | "))")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateAutoHide()
        }
        log("taskbar ready")
    }

    @objc func refresh() {
        processCommandFile()

        let screens = collectScreens()
        let screenIDs = Set(screens.map(\.id))

        for staleID in panels.keys where !screenIDs.contains(staleID) {
            panels[staleID]?.close()
            panels.removeValue(forKey: staleID)
        }

        for screen in screens where panels[screen.id] == nil {
            panels[screen.id] = TaskbarPanel(screen: screen, values: settings.values(for: screen.id), controller: self)
        }

        let records = collectWindowRecords(screens: screens)
        let visible = visibleWindows(records, currentPID: currentPID())
        let currentFrontmostPID = frontmostPID()

        for screen in screens {
            let screenWindows = visible.filter { $0.screenID == screen.id }
            let values = settings.values(for: screen.id)
            let items = buildTaskbarItems(
                windows: screenWindows,
                frontmostPID: currentFrontmostPID,
                groupByApp: false,
                pinnedApps: values.pinnedApps
            )
            panels[screen.id]?.update(screen: screen, items: items, values: values)
        }

        windowAvoider.keepWindowsAboveTaskbars(
            records: visible,
            screens: screens,
            settings: settings,
            currentPID: currentPID()
        )
    }

    func activate(item: TaskbarItem) {
        let pidText = item.pid.map(String.init) ?? "not-running"
        log("activating \(item.owner) pid=\(pidText) windows=\(item.windowIDs)")
        if let pid = item.pid {
            _ = activateApplication(pid: pid)
        } else {
            _ = launchApplication(appPath: item.appPath, bundleID: item.bundleID)
        }
        refresh()
    }

    private func processCommandFile() {
        guard let command = try? String(contentsOf: commandFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !command.isEmpty
        else {
            return
        }

        try? FileManager.default.removeItem(at: commandFileURL)

        switch command {
        case "show-settings":
            log("command show-settings")
            showSettings()
        default:
            log("unknown command \(command)")
        }
    }

    private func updateAutoHide() {
        let mouseLocation = NSEvent.mouseLocation
        panels.values.forEach { $0.updateAutoHide(mouseLocation: mouseLocation, animated: true) }
    }

    func makeSettingsMenu(screenID: UInt32? = nil) -> NSMenu {
        menuScreenContext = screenID
        let menu = NSMenu(title: "Taskbar")

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Taskbar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    func makeItemMenu(for item: TaskbarItem, screenID: UInt32) -> NSMenu {
        menuItemContext = (screenID, item)

        let menu = NSMenu(title: item.owner)
        let pinTitle = item.isPinned ? "Unpin \(item.owner)" : "Pin \(item.owner)"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(togglePinnedMenuItem), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        if item.pid != nil {
            let forceQuitItem = NSMenuItem(title: "Force Quit \(item.owner)", action: #selector(forceQuitMenuItem), keyEquivalent: "")
            forceQuitItem.target = self
            menu.addItem(forceQuitItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        return menu
    }

    @objc func showSettings() {
        showSettings(screenID: nil)
    }

    @objc private func showSettingsFromMenu() {
        showSettings(screenID: menuScreenContext)
    }

    func showSettings(screenID: UInt32?) {
        let screens = collectScreens()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, screens: screens)
        } else {
            settingsWindowController?.updateScreens(screens)
        }
        if let screenID {
            settingsWindowController?.selectMonitor(screenID: screenID)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func togglePinnedMenuItem() {
        guard let context = menuItemContext else { return }
        let app = PinnedApp(
            displayName: context.item.owner,
            bundleID: context.item.bundleID,
            appPath: context.item.appPath
        )

        if context.item.isPinned {
            settings.unpin(app, for: context.screenID)
        } else {
            settings.pin(app, for: context.screenID)
        }
        refresh()
    }

    func movePinnedItem(_ item: TaskbarItem, before target: TaskbarItem?, screenID: UInt32) {
        settings.movePinnedApp(
            movingIdentity: item.identity,
            beforeIdentity: target?.identity,
            for: screenID
        )
        refresh()
    }

    @objc private func forceQuitMenuItem() {
        guard let pid = menuItemContext?.item.pid else { return }
        _ = forceQuitApplication(pid: pid)
        refresh()
    }

    private func syncStartAtLogin() {
        StartupManager.setEnabled(settings.preferences.startAtLogin)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
