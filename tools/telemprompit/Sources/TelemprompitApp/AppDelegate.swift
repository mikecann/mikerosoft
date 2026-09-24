import AppKit
import ApplicationServices
import Carbon
import Combine
import PrompterKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PrompterModel()
    private lazy var prompter = PrompterWindowController(model: model)
    private let hotkeys = GlobalHotkeys()
    private var settingsWindow: NSWindow?
    private var settingsTab = SettingsView.Tab.script
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        prompter.openSettings = { [weak self] in self?.showSettings(tab: .appearance) }

        // `--script path` loads a file, for testing and for launching from scripts.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--script"), arguments.indices.contains(flag + 1),
           let text = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8) {
            model.load(text)
        }

        model.$settings
            .map { ($0.clickerKeysGlobal, $0.globalShortcuts) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] clicker, shortcuts in
                self?.registerHotkeys(clicker: clicker, shortcuts: shortcuts)
            }
            .store(in: &cancellables)

        prompter.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.host?.lowercased() == "settings" {
                showSettings(tab: .appearance)
            } else {
                RemoteCommand(url: url)?.perform(on: model)
            }
        }
    }

    private func registerHotkeys(clicker: Bool, shortcuts: Bool) {
        var bindings: [GlobalHotkeys.Binding] = []
        let model = model
        if clicker {
            bindings += [
                .init(keyCode: kVK_PageDown, modifiers: 0) { model.next() },
                .init(keyCode: kVK_PageUp, modifiers: 0) { model.previous() },
            ]
        }
        if shortcuts {
            let modifiers = controlKey | optionKey
            bindings += [
                .init(keyCode: kVK_RightArrow, modifiers: modifiers) { model.next() },
                .init(keyCode: kVK_LeftArrow, modifiers: modifiers) { model.previous() },
                .init(keyCode: kVK_Space, modifiers: modifiers) { model.toggleScrolling() },
            ]
        }
        hotkeys.replace(with: bindings)
    }

    // MARK: - Settings

    @objc func showSettingsFromMenu(_ sender: Any?) { showSettings(tab: .appearance) }
    @objc func editScript(_ sender: Any?) { showSettings(tab: .script) }

    func showSettings(tab: SettingsView.Tab) {
        settingsTab = tab
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.contentView = NSHostingView(rootView: settingsView())
        if !window.isVisible {
            // Open on the main screen, not the prompter, which may be mirrored.
            let screen = NSScreen.screens.first { !PrompterDisplay.isPrompterDisplay(named: $0.localizedName) }
                ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2
                ))
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func settingsView() -> some View {
        SettingsView(
            model: model,
            tab: Binding(get: { [weak self] in self?.settingsTab ?? .script }, set: { [weak self] in self?.settingsTab = $0 }),
            prompterStatus: { [weak self] in
                guard let self else { return "" }
                let name = self.prompter.screenDescription
                return self.prompter.isOnPrompter ? name : "\(name) (Elgato Prompter not found)"
            },
            movePrompter: { [weak self] in self?.prompter.placeOnPreferredScreen() },
            turnOnPrompter: { [weak self] in self?.turnOnPrompter(nil) }
        )
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Telemprompit Settings"
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - Menu actions

    @objc func pasteNewScript(_ sender: Any?) { model.pasteFromClipboard() }
    @objc func next(_ sender: Any?) { model.next() }
    @objc func previous(_ sender: Any?) { model.previous() }
    @objc func restart(_ sender: Any?) { model.restart() }
    @objc func toggleScrolling(_ sender: Any?) { model.toggleScrolling() }
    @objc func faster(_ sender: Any?) { model.changeSpeed(by: 1.2) }
    @objc func slower(_ sender: Any?) { model.changeSpeed(by: 1 / 1.2) }
    @objc func biggerText(_ sender: Any?) { model.changeFontSize(by: 4) }
    @objc func smallerText(_ sender: Any?) { model.changeFontSize(by: -4) }
    @objc func toggleMirror(_ sender: Any?) { model.settings.mirrorHorizontally.toggle() }
    @objc func toggleKeepOnTop(_ sender: Any?) { model.settings.keepOnTop.toggle() }
    @objc func toggleFill(_ sender: Any?) { prompter.toggleFill() }
    @objc func moveToPrompter(_ sender: Any?) { prompter.placeOnPreferredScreen() }
    // performClose needs a close button, which the borderless prompter lacks.
    @objc func closeKeyWindow(_ sender: Any?) { NSApp.keyWindow?.close() }

    @objc func turnOnPrompter(_ sender: Any?) {
        if PrompterDisplay.prompterScreen() != nil {
            prompter.placeOnPreferredScreen()
            return
        }
        guard AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        ) else {
            showAlert(
                "Telemprompit needs Accessibility permission",
                "It switches the prompter on by pressing the Elgato Prompter switch in DisplayLink Manager. Allow Telemprompit in System Settings > Privacy & Security > Accessibility, then try again."
            )
            return
        }
        DisplayLinkTeleprompterController.shared.setEnabled(true) { [weak self] result in
            if case let .failure(error) = result {
                self?.showAlert("Couldn't turn on the Elgato Prompter", error.localizedDescription)
            }
            // The screen-change notification moves the window once macOS
            // has added the display.
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleScrolling(_:)):
            item.title = model.isScrolling ? "Pause Auto-scroll" : "Start Auto-scroll"
        case #selector(toggleMirror(_:)):
            item.state = model.settings.mirrorHorizontally ? .on : .off
        case #selector(toggleKeepOnTop(_:)):
            item.state = model.settings.keepOnTop ? .on : .off
        default:
            break
        }
        return true
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Telemprompit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMenu(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Telemprompit", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Telemprompit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "Telemprompit", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let script = NSMenu(title: "Script")
        script.addItem(withTitle: "Paste New Script", action: #selector(pasteNewScript(_:)), keyEquivalent: "V")
        script.addItem(withTitle: "Edit Script…", action: #selector(editScript(_:)), keyEquivalent: "e")
        script.addItem(.separator())
        script.addItem(withTitle: "Next Line", action: #selector(next(_:)), keyEquivalent: "")
        script.addItem(withTitle: "Previous Line", action: #selector(previous(_:)), keyEquivalent: "")
        script.addItem(withTitle: "Back to Start", action: #selector(restart(_:)), keyEquivalent: "")
        script.addItem(.separator())
        script.addItem(withTitle: "Start Auto-scroll", action: #selector(toggleScrolling(_:)), keyEquivalent: "p")
        script.addItem(withTitle: "Scroll Faster", action: #selector(faster(_:)), keyEquivalent: "]")
        script.addItem(withTitle: "Scroll Slower", action: #selector(slower(_:)), keyEquivalent: "[")
        add(script, titled: "Script", to: main)

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger Text", action: #selector(biggerText(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller Text", action: #selector(smallerText(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Mirror Horizontally", action: #selector(toggleMirror(_:)), keyEquivalent: "M")
        view.addItem(.separator())
        view.addItem(withTitle: "Fill Display", action: #selector(toggleFill(_:)), keyEquivalent: "f")
        view.addItem(withTitle: "Keep on Top", action: #selector(toggleKeepOnTop(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Move to Prompter Display", action: #selector(moveToPrompter(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Turn On Elgato Prompter", action: #selector(turnOnPrompter(_:)), keyEquivalent: "")
        add(view, titled: "View", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(closeKeyWindow(_:)), keyEquivalent: "w")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
