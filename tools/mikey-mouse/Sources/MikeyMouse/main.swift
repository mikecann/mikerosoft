import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var engine = MouseEngine(settings: settings)
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var lastPermissionState: Bool?
    private var loggedStartFailure = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        AccessibilityPermission.requestIfNeeded()
        updateEngine()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateEngine()
        }
        log("mikey-mouse started pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        engine.stop()
        log("mikey-mouse stopped")
    }

    /// Starts the event tap once Accessibility is granted, and stops it if the
    /// permission is taken away.
    private func updateEngine() {
        let granted = AccessibilityPermission.isGranted
        let wasRunning = engine.isRunning

        if granted, !engine.isRunning {
            if engine.start() {
                log("event tap started")
                loggedStartFailure = false
            } else if !loggedStartFailure {
                log("event tap could not start yet")
                loggedStartFailure = true
            }
        } else if !granted, engine.isRunning {
            engine.stop()
            log("accessibility permission removed, event tap stopped")
        }

        if granted != lastPermissionState || engine.isRunning != wasRunning {
            lastPermissionState = granted
            refreshMenu()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Mikey Mouse")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let statusItem else {
            return
        }

        let current = settings.current
        statusItem.button?.title = engine.isRunning ? "" : "!"

        let menu = NSMenu()

        let header = NSMenuItem(
            title: engine.isRunning ? "Mikey Mouse" : "Mikey Mouse needs Accessibility permission",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(
            toggleItem(
                "Back and Forward Buttons",
                isOn: current.backForwardEnabled,
                action: #selector(toggleBackForward)
            )
        )
        menu.addItem(
            toggleItem(
                "Smooth Scrolling",
                isOn: current.smoothScrollingEnabled,
                action: #selector(toggleSmoothScrolling)
            )
        )
        menu.addItem(
            choiceMenu(
                "Scroll Speed",
                choices: ScrollSpeed.allCases.map { ($0.title, $0.rawValue) },
                selected: current.scrollSpeed.rawValue,
                action: #selector(selectScrollSpeed(_:))
            )
        )
        menu.addItem(
            choiceMenu(
                "Smoothness",
                choices: Smoothness.allCases.map { ($0.title, $0.rawValue) },
                selected: current.smoothness.rawValue,
                action: #selector(selectSmoothness(_:))
            )
        )

        menu.addItem(.separator())

        if !AccessibilityPermission.isGranted {
            let permissionItem = NSMenuItem(
                title: "Grant Accessibility Permission…",
                action: #selector(requestAccessibilityPermission),
                keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
        }

        menu.addItem(
            toggleItem(
                "Start at Login",
                isOn: StartupManager.isEnabled,
                action: #selector(toggleStartAtLogin)
            )
        )

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Mikey Mouse", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func toggleItem(_ title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    private func choiceMenu(
        _ title: String,
        choices: [(title: String, value: String)],
        selected: String,
        action: Selector
    ) -> NSMenuItem {
        let submenu = NSMenu()
        for choice in choices {
            let item = NSMenuItem(title: choice.title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = choice.value
            item.state = choice.value == selected ? .on : .off
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc private func toggleBackForward() {
        settings.update { $0.backForwardEnabled.toggle() }
        refreshMenu()
    }

    @objc private func toggleSmoothScrolling() {
        settings.update { $0.smoothScrollingEnabled.toggle() }
        refreshMenu()
    }

    @objc private func selectScrollSpeed(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let speed = ScrollSpeed(rawValue: value) else {
            return
        }
        settings.update { $0.scrollSpeed = speed }
        refreshMenu()
    }

    @objc private func selectSmoothness(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let smoothness = Smoothness(rawValue: value) else {
            return
        }
        settings.update { $0.smoothness = smoothness }
        refreshMenu()
    }

    @objc private func requestAccessibilityPermission() {
        AccessibilityPermission.requestIfNeeded()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleStartAtLogin() {
        do {
            try StartupManager.setEnabled(!StartupManager.isEnabled)
        } catch {
            log("failed to update start-at-login setting: \(error)")
        }
        refreshMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let bundleID = Bundle.main.bundleIdentifier ?? "com.mikerosoft.mikey-mouse"
let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !otherInstances.isEmpty {
    // Two event taps would both try to smooth the same wheel.
    log("another Mikey Mouse is already running, exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
