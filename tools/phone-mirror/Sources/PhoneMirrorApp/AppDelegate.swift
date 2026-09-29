import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let phones = PhoneScreenDevices()
    private var mirrors: [String: MirrorWindowController] = [:]
    /// Phones whose window the user closed. They stay closed until unplugged or reopened from the Phones menu.
    private var closedByUser: Set<String> = []
    private let phonesMenu = NSMenu(title: "Phones")
    private var waitingWindow: NSWindow?
    /// Phones take a moment to appear after launch, so the waiting window holds off briefly.
    private var launchGraceOver = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        rebuildPhonesMenu()
        Log.info("launched, camera access \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Log.info("camera access granted=\(granted)")
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.showCameraAccessAlert()
                    return
                }
                self.phones.onChange = { [weak self] devices in self?.update(devices) }
                self.phones.start()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.launchGraceOver = true
            self?.updateWaitingWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        mirrors.values.forEach { $0.stopHelper() }
    }

    /// `open -g phonemirror://<command>` drives the first phone from the terminal, so control can
    /// be tested without clicking. See `MirrorWindowController.perform(_:)` for the commands.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let mirror = phones.devices.first.flatMap({ mirrors[$0.uniqueID] }) else {
                Log.info("url \(url.absoluteString): no phone window open")
                continue
            }
            Log.info("url \(url.absoluteString)")
            mirror.perform(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showAllPhones(nil) }
        return true
    }

    // MARK: - Phones

    private func update(_ devices: [AVCaptureDevice]) {
        let connected = Set(devices.map(\.uniqueID))
        Log.info("phones: \(devices.map(\.localizedName))")

        for (id, mirror) in mirrors where !connected.contains(id) {
            mirrors[id] = nil
            mirror.close()
        }
        closedByUser.formIntersection(connected)
        for device in devices where mirrors[device.uniqueID] == nil && !closedByUser.contains(device.uniqueID) {
            open(device)
        }
        rebuildPhonesMenu()
        updateWaitingWindow()
    }

    private func open(_ device: AVCaptureDevice) {
        if let existing = mirrors[device.uniqueID] {
            existing.showWindow(nil)
            return
        }
        closedByUser.remove(device.uniqueID)
        let mirror = MirrorWindowController(device: device)
        mirror.onClose = { [weak self] closed in self?.mirrorDidClose(closed) }
        mirrors[device.uniqueID] = mirror
        mirror.start()
    }

    private func mirrorDidClose(_ mirror: MirrorWindowController) {
        let id = mirror.device.uniqueID
        // Unplugging removes the mirror before closing it, so anything still listed was closed by the user.
        if mirrors[id] === mirror {
            mirrors[id] = nil
            closedByUser.insert(id)
        }
        updateWaitingWindow()
    }

    @objc private func showPhone(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let device = phones.devices.first(where: { $0.uniqueID == id }) else { return }
        open(device)
    }

    @objc func showAllPhones(_ sender: Any?) {
        phones.devices.forEach(open)
        updateWaitingWindow(force: true)
    }

    // MARK: - Waiting window

    private func updateWaitingWindow(force: Bool = false) {
        let noPhones = phones.devices.isEmpty
        if noPhones && (launchGraceOver || force) {
            let window = waitingWindow ?? makeWaitingWindow()
            waitingWindow = window
            if !window.isVisible {
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
        } else if !noPhones {
            waitingWindow?.orderOut(nil)
        }
    }

    private func makeWaitingWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Phone Mirror"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WaitingView())
        return window
    }

    private func showCameraAccessAlert() {
        let alert = NSAlert()
        alert.messageText = "Phone Mirror needs camera access"
        alert.informativeText = "macOS treats a plugged-in iPhone's screen as a camera. Turn on Phone Mirror in Privacy & Security > Camera, then reopen it."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    // MARK: - Menus

    private var keyMirror: MirrorWindowController? {
        mirrors.values.first { $0.window?.isKeyWindow == true }
    }

    @objc private func toggleFloating(_ sender: Any?) { keyMirror?.toggleFloating() }
    @objc private func showActualSize(_ sender: Any?) { keyMirror?.showActualSize() }
    @objc private func pressHome(_ sender: Any?) { keyMirror?.pressHome() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFloating(_:)):
            menuItem.state = keyMirror?.isFloating == true ? .on : .off
            return keyMirror != nil
        case #selector(showActualSize(_:)), #selector(pressHome(_:)):
            return keyMirror != nil
        case #selector(showAllPhones(_:)):
            return !phones.devices.isEmpty
        default:
            return true
        }
    }

    private func rebuildPhonesMenu() {
        phonesMenu.removeAllItems()
        if phones.devices.isEmpty {
            let empty = NSMenuItem(title: "No Phones Plugged In", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            phonesMenu.addItem(empty)
        }
        for (index, device) in phones.devices.enumerated() {
            let item = NSMenuItem(
                title: device.localizedName,
                action: #selector(showPhone(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : ""
            )
            item.representedObject = device.uniqueID
            item.target = self
            phonesMenu.addItem(item)
        }
        phonesMenu.addItem(.separator())
        phonesMenu.addItem(withTitle: "Show All Phones", action: #selector(showAllPhones(_:)), keyEquivalent: "n")
        let home = phonesMenu.addItem(withTitle: "Home", action: #selector(pressHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Phone Mirror", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Phone Mirror", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Phone Mirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Phone Mirror")

        main.addItem(submenu: phonesMenu, title: "Phones")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste to Phone", action: #selector(MirrorView.paste(_:)), keyEquivalent: "v")
        main.addItem(submenu: editMenu, title: "Edit")

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(showActualSize(_:)), keyEquivalent: "0")
        main.addItem(submenu: viewMenu, title: "View")

        let windowMenu = NSMenu(title: "Window")
        let float = windowMenu.addItem(withTitle: "Float on Top", action: #selector(toggleFloating(_:)), keyEquivalent: "t")
        float.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
