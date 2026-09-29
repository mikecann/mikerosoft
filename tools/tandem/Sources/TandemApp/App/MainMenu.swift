import AppKit

/// Receives menu commands. The project window controller and the app
/// delegate both implement this, so the responder chain picks the right one.
@MainActor @objc protocol EditorCommandHandling {
    func performEditorCommand(_ sender: Any?)
}

/// The menu bar. Items carry an `EditorCommand` and go down the responder
/// chain as `performEditorCommand(_:)`; key equivalents come from the
/// keymap so menus show what the keys really do.
@MainActor
enum MainMenu {
    static let recentMenuTitle = "Open recent"

    static func build(keymap: Keymap, recentDelegate: NSMenuDelegate) -> NSMenu {
        let main = EditorMainMenu()

        let app = submenu(main, "Tandem")
        app.addItem(withTitle: "About Tandem", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Tandem", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show all", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Tandem", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        add(file, .newProject, keymap)
        add(file, .openProject, keymap)
        let recent = NSMenu(title: recentMenuTitle)
        recent.delegate = recentDelegate
        file.addItem(withTitle: recentMenuTitle, action: nil, keyEquivalent: "").submenu = recent
        file.addItem(.separator())
        file.addItem(withTitle: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, .save, keymap)
        add(file, .saveVersion, keymap)
        file.addItem(.separator())
        add(file, .export, keymap)
        file.addItem(.separator())
        file.addItem(withTitle: "Show project in Finder", action: #selector(ProjectWindowController.revealProject(_:)), keyEquivalent: "")

        let edit = submenu(main, "Edit")
        add(edit, .undo, keymap)
        add(edit, .redo, keymap)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(.separator())
        add(edit, .lift, keymap)
        add(edit, .rippleDelete, keymap)
        edit.addItem(.separator())
        add(edit, .selectAll, keymap)
        add(edit, .deselectAll, keymap)
        add(edit, .selectForward, keymap)

        let timeline = submenu(main, "Timeline")
        for command: EditorCommand in [.bladeAtPlayhead, .rippleTrimStart, .rippleTrimEnd, .liftInOut, .extractInOut] {
            add(timeline, command, keymap)
        }
        timeline.addItem(.separator())
        for command: EditorCommand in [.markIn, .markOut, .markClip, .clearInOut] {
            add(timeline, command, keymap)
        }
        timeline.addItem(.separator())
        for command: EditorCommand in [.addMarker, .previousMarker, .nextMarker] {
            add(timeline, command, keymap)
        }
        timeline.addItem(.separator())
        for command: EditorCommand in [.toggleKeyframe, .previousKeyframe, .nextKeyframe] {
            add(timeline, command, keymap)
        }
        timeline.addItem(.separator())
        for command: EditorCommand in [.addVideoTrack, .addAudioTrack] {
            add(timeline, command, keymap)
        }
        timeline.addItem(.separator())
        for command: EditorCommand in [.addTransition, .link, .nudgeLeft, .nudgeRight] {
            add(timeline, command, keymap)
        }
        timeline.addItem(.separator())
        let layout = NSMenu(title: "Layout")
        for command: EditorCommand in [.layoutFull, .layoutPipRight, .layoutPipLeft, .layoutSplit] {
            add(layout, command, keymap)
        }
        timeline.addItem(withTitle: "Layout", action: nil, keyEquivalent: "").submenu = layout
        let tools = NSMenu(title: "Tool")
        for command: EditorCommand in [.toolSelect, .toolBlade, .toolRippleTrim, .toolRoll, .toolSlip, .toolSlide] {
            add(tools, command, keymap)
        }
        timeline.addItem(withTitle: "Tool", action: nil, keyEquivalent: "").submenu = tools
        timeline.addItem(.separator())
        for command: EditorCommand in [.toggleSnapping, .toggleLinkedSelection, .toggleRipple] {
            add(timeline, command, keymap)
        }

        let playback = submenu(main, "Playback")
        for command: EditorCommand in [.playPause, .shuttleReverse, .shuttleStop, .shuttleForward] {
            add(playback, command, keymap)
        }
        playback.addItem(.separator())
        for command: EditorCommand in [.stepBack, .stepForward, .stepBackFive, .stepForwardFive] {
            add(playback, command, keymap)
        }
        playback.addItem(.separator())
        for command: EditorCommand in [.goToStart, .goToEnd, .previousEdit, .nextEdit] {
            add(playback, command, keymap)
        }

        let view = submenu(main, "View")
        for command: EditorCommand in [.zoomIn, .zoomOut, .zoomToFit] {
            add(view, command, keymap)
        }
        view.addItem(.separator())
        for command: EditorCommand in [.toggleTranscriptLane, .toggleSafeMargins, .toggleProxy] {
            add(view, command, keymap)
        }
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter full screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring all to front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        help.addItem(withTitle: "Show keymap file", action: #selector(AppDelegate.showKeymapFile(_:)), keyEquivalent: "")
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ command: EditorCommand, _ keymap: Keymap) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: #selector(EditorCommandHandling.performEditorCommand(_:)), keyEquivalent: "")
        item.representedObject = command.rawValue
        if let icon = Icons.command(command) { item.image = Icons.menuImage(icon) }
        // Every key shows, plain ones too (B, I, J); `EditorMainMenu`
        // leaves plain keys to the keyboard router.
        if let chord = keymap.menuChord(for: command), let equivalent = chord.displayKeyEquivalent {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        menu.addItem(item)
        return item
    }

    static func command(of sender: Any?) -> EditorCommand? {
        guard let item = sender as? NSMenuItem, let raw = item.representedObject as? String else { return nil }
        return EditorCommand(rawValue: raw)
    }
}

/// The menu bar. It shows plain-key shortcuts (B for the blade, I and O for
/// in and out) so they're easy to learn, but doesn't act on them: AppKit
/// offers the menu bar every key before the window, so a plain B there
/// would stop a text field getting its b. Keys without Command go on to
/// the window, where the keyboard router runs them (and text
/// fields get them while you type). Only Command keys act here, as before.
final class EditorMainMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else { return false }
        return super.performKeyEquivalent(with: event)
    }
}
