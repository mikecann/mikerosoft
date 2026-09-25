import AppKit

extension KeyChord {
    /// Key codes for keys that don't type a character.
    static let namedKeyCodes: [UInt16: String] = [
        49: "space", 51: "delete", 117: "forwarddelete", 36: "return", 76: "enter", 53: "escape", 48: "tab",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"
    ]

    /// The chord a key event represents. Uses the unshifted character, so
    /// Shift-comma is `shift+,` on any layout that types a comma there.
    init?(event: NSEvent) {
        var modifiers: Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if let name = Self.namedKeyCodes[event.keyCode] {
            self.init(key: name, modifiers: modifiers)
            return
        }
        guard let characters = event.characters(byApplyingModifiers: []), characters.count == 1 else { return nil }
        self.init(key: characters.lowercased(), modifiers: modifiers)
    }

    /// The menu key equivalent, for chords menus can show (they need Cmd,
    /// otherwise the menu would steal plain keys from text fields).
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard modifiers.contains(.command) else { return nil }
        var flags: NSEvent.ModifierFlags = [.command]
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        let special: [String: Int] = [
            "delete": NSBackspaceCharacter, "forwarddelete": NSDeleteFunctionKey, "left": NSLeftArrowFunctionKey,
            "right": NSRightArrowFunctionKey, "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey,
            "return": NSCarriageReturnCharacter, "escape": 0x1B, "tab": NSTabCharacter, "space": 0x20,
            "home": NSHomeFunctionKey, "end": NSEndFunctionKey
        ]
        if let code = special[key], let scalar = UnicodeScalar(code) {
            return (String(Character(scalar)), flags)
        }
        guard key.count == 1 else { return nil }
        return (key, flags)
    }
}

/// Sends key presses in a project window to the keymap, unless someone is
/// typing in a text field. Premiere's single-key shortcuts (J, K, L, I, O,
/// Q, W...) have to work wherever the pointer is, so this listens to the
/// window rather than waiting for a view to become first responder.
@MainActor
final class KeyboardRouter {
    var keymap: Keymap
    weak var window: NSWindow?
    /// Runs a command. Returns false when it couldn't be done, which beeps.
    var perform: (EditorCommand) -> Bool = { _ in false }
    /// Frame steps while K is held, like Premiere's K+J and K+L.
    var step: (Int64) -> Void = { _ in }
    /// True while something modal (the export sheet) owns the keyboard.
    var isBlocked: () -> Bool = { false }
    /// Keys that act while held rather than when pressed: Z turns viewer
    /// drags into zoom rectangles.
    var holdChanged: (String, Bool) -> Void = { _, _ in }
    static let holdKeys: Set<String> = ["z"]
    private var monitor: Any?
    private var holdingK = false

    init(keymap: Keymap) {
        self.keymap = keymap
    }

    func install(on window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when a text field (or any editable text) has the keyboard.
    var isEditingText: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }

    /// Returns true when the event was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil, !isEditingText, !isBlocked() else {
            return false
        }
        guard let chord = KeyChord(event: event) else { return false }
        return route(chord, keyUp: event.type == .keyUp, isRepeat: event.isARepeat)
    }

    /// The routing itself, separate from `NSEvent` so it can be tested.
    /// Returns true when the key was used.
    func route(_ chord: KeyChord, keyUp: Bool, isRepeat: Bool) -> Bool {
        if keyUp {
            if chord.key == "k" { holdingK = false }
            if Self.holdKeys.contains(chord.key) { holdChanged(chord.key, false) }
            return false
        }
        if chord.modifiers.isEmpty, Self.holdKeys.contains(chord.key), keymap.command(for: chord) == nil {
            if !isRepeat { holdChanged(chord.key, true) }
            return true
        }
        if chord.key == "k" && chord.modifiers.isEmpty {
            holdingK = true
        } else if holdingK && chord.modifiers.isEmpty && (chord.key == "j" || chord.key == "l") {
            step(chord.key == "l" ? 1 : -1)
            return true
        }
        guard let command = keymap.command(for: chord) else { return false }
        if isRepeat && !Self.repeatable.contains(command) { return true }
        if !perform(command) { NSSound.beep() }
        return true
    }

    /// Commands that make sense to repeat while a key is held.
    static let repeatable: Set<EditorCommand> = [
        .stepBack, .stepForward, .stepBackFive, .stepForwardFive, .nudgeLeft, .nudgeRight,
        .nudgeLeftFive, .nudgeRightFive, .zoomIn, .zoomOut, .previousEdit, .nextEdit, .undo, .redo
    ]
}
