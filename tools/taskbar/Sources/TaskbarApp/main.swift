import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TaskbarController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = TaskbarController()
        controller?.start()
        installStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
        log("taskbar event loop exited")
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "TB"
        item.menu = controller?.makeSettingsMenu()
        statusItem = item
    }
}

guard let singleInstance = SingleInstance.acquire() else {
    log("taskbar already running; exiting duplicate launch")
    exit(0)
}

log("taskbar starting pid=\(ProcessInfo.processInfo.processIdentifier)")

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
_ = singleInstance
