import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TaskbarController?
    private var statusItem: NSStatusItem?
    private var terminationLifecycle: AppTerminationLifecycle?
    private var terminationSignalBridge: TerminationSignalBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = TaskbarController()
        self.controller = controller
        let terminationLifecycle = AppTerminationLifecycle(
            prepareForTermination: { controller.prepareForTermination() },
            requestApplicationTermination: { NSApp.terminate(nil) }
        )
        self.terminationLifecycle = terminationLifecycle
        let terminationSignalBridge = TerminationSignalBridge(
            onSignal: { terminationLifecycle.requestTerminationFromSignal() }
        )
        self.terminationSignalBridge = terminationSignalBridge
        terminationSignalBridge.start()
        controller.start()
        installStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationLifecycle?.applicationWillTerminate()
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
let backgroundCursorResult = enableTaskbarBackgroundCursorUpdates()
if backgroundCursorResult != .success {
    log("could not enable background cursor updates error=\(backgroundCursorResult.rawValue)")
}
app.delegate = delegate
app.run()
_ = singleInstance
