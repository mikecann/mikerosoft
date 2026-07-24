import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = AppMonitor()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        monitor.onStatusChanged = { [weak self] in
            self?.refreshMenu()
        }
        monitor.start()
        log("last-window-quits started pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        log("last-window-quits stopped")
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LWQ"
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let statusItem else {
            return
        }

        statusItem.button?.title = AccessibilityPermission.isGranted ? "LWQ" : "LWQ!"

        let menu = NSMenu()

        let enabledItem = NSMenuItem(
            title: "Quit apps after their last window closes",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = monitor.isEnabled ? .on : .off
        menu.addItem(enabledItem)

        if !AccessibilityPermission.isGranted {
            let permissionItem = NSMenuItem(
                title: "Grant Accessibility Permission…",
                action: #selector(requestAccessibilityPermission),
                keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
        }

        let startupItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleStartAtLogin),
            keyEquivalent: ""
        )
        startupItem.target = self
        startupItem.state = StartupManager.isEnabled ? .on : .off
        menu.addItem(startupItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Last Window Quits",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        monitor.isEnabled.toggle()
        refreshMenu()
    }

    @objc private func requestAccessibilityPermission() {
        AccessibilityPermission.requestIfNeeded()
        refreshMenu()
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
