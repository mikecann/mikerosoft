import AppKit
import Combine
import PrompterKit
import SwiftUI

private final class PrompterWindow: NSWindow {
    // Borderless windows refuse key status by default, which would stop
    // keyboard navigation and paste.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var onPaste: () -> Void = {}

    @objc func paste(_ sender: Any?) {
        onPaste()
    }
}

/// Lets the first click on an inactive window advance the script instead of
/// only activating the app.
private final class PrompterHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PrompterWindowController: NSObject, NSWindowDelegate {
    let model: PrompterModel
    var openSettings: () -> Void = {}

    private let window: PrompterWindow
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var isPlacing = false
    private var frameBeforeFill: NSRect?

    init(model: PrompterModel) {
        self.model = model
        window = PrompterWindow(
            contentRect: NSRect(origin: .zero, size: WindowPlacement.fallbackSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Telemprompit"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 200)
        window.hasShadow = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.onPaste = { [weak model] in model?.pasteFromClipboard() }
        window.contentView = PrompterHostingView(
            rootView: PrompterView(model: model, openSettings: { [weak self] in self?.openSettings() })
        )

        model.$settings
            .map(\.keepOnTop)
            .removeDuplicates()
            .sink { [weak self] onTop in self?.window.level = onTop ? .floating : .normal }
            .store(in: &cancellables)

        installEventMonitors()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func publishDisplayStatus() {
        let name = window.screen?.localizedName ?? "no screen"
        model.displayStatus = isOnPrompter ? name : "\(name) (Elgato Prompter not found)"
    }

    var isOnPrompter: Bool {
        window.screen.map { PrompterDisplay.isPrompterDisplay(named: $0.localizedName) } ?? false
    }

    func show() {
        placeOnPreferredScreen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func placeOnPreferredScreen() {
        guard let target = WindowPlacement.targetScreen(in: WindowPlacement.screens()) else { return }
        isPlacing = true
        window.setFrame(WindowPlacement.frame(on: target, saved: WindowPlacement.savedFrames()), display: true)
        isPlacing = false
        frameBeforeFill = nil
        publishDisplayStatus()
    }

    /// Toggles between filling the current display and the previous frame.
    func toggleFill() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let fill = PrompterDisplay.fillFrame(in: screen.visibleFrame)
        if let previous = frameBeforeFill, window.frame == fill {
            window.setFrame(previous, display: true, animate: true)
            frameBeforeFill = nil
        } else {
            frameBeforeFill = window.frame
            window.setFrame(fill, display: true, animate: true)
        }
    }

    @objc private func screensChanged() {
        publishDisplayStatus()
        guard model.settings.followPrompter, !isOnPrompter,
              PrompterDisplay.prompterScreen() != nil
        else { return }
        placeOnPreferredScreen()
    }

    // MARK: - Remember where the window was put on each display

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidChangeScreen(_ notification: Notification) { publishDisplayStatus() }
    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) {
        if !window.inLiveResize { rememberFrame() }
    }

    private func rememberFrame() {
        guard !isPlacing, let screen = window.screen else { return }
        WindowPlacement.save(window.frame, for: screen.localizedName)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // MARK: - Keyboard, right-click and scroll wheel

    private func installEventMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
        // Clicks are handled here rather than with a SwiftUI tap gesture so
        // the first click on an unfocused prompter also advances the script.
        let leftClick = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window,
                  let size = self.window.contentView?.bounds.size,
                  PrompterClickZones.advances(at: event.locationInWindow, in: size)
            else { return event }
            self.model.next()
            return event
        }
        let rightClick = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.model.previous()
            return nil
        }
        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            self.model.nudge(by: -event.scrollingDeltaY * scale)
            return nil
        }
        monitors = [keys, leftClick, rightClick, scroll].compactMap { $0 }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "v" {
            model.pasteFromClipboard()
            return true
        }
        guard modifiers.subtracting(.shift).isEmpty else { return false }

        switch Int(event.keyCode) {
        case KeyCode.space, KeyCode.return, KeyCode.rightArrow, KeyCode.downArrow, KeyCode.pageDown:
            model.next()
        case KeyCode.leftArrow, KeyCode.upArrow, KeyCode.pageUp:
            model.previous()
        case KeyCode.home:
            model.restart()
        case KeyCode.end:
            model.end()
        case KeyCode.escape:
            model.stopScrolling()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "p": model.toggleScrolling()
            case "]": model.changeSpeed(by: 1.2)
            case "[": model.changeSpeed(by: 1 / 1.2)
            case "=", "+": model.changeFontSize(by: 4)
            case "-": model.changeFontSize(by: -4)
            case "m": model.settings.mirrorHorizontally.toggle()
            default: return false
            }
        }
        return true
    }
}

/// The top strip holds the drag handle and its buttons, and the bottom-right
/// corner holds the resize grip. A click anywhere else advances.
enum PrompterClickZones {
    static let handleStripHeight: CGFloat = 44
    static let resizeGripSize: CGFloat = 28

    /// `point` is in AppKit window coordinates, with the origin bottom-left.
    static func advances(at point: CGPoint, in size: CGSize) -> Bool {
        if point.y > size.height - handleStripHeight { return false }
        if point.x > size.width - resizeGripSize, point.y < resizeGripSize { return false }
        return true
    }
}

enum KeyCode {
    static let `return` = 36
    static let space = 49
    static let escape = 53
    static let home = 115
    static let pageUp = 116
    static let end = 119
    static let pageDown = 121
    static let leftArrow = 123
    static let rightArrow = 124
    static let downArrow = 125
    static let upArrow = 126
}
