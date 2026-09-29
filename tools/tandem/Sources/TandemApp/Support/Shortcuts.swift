import AppKit

/// The keys bound to commands, for tooltips and menus, so they teach the
/// shortcuts as you go. They read the live keymap, so a custom keymap
/// shows its own keys.
@MainActor
enum Shortcuts {
    static var keymap: Keymap { ProjectDocuments.shared.keymap }

    /// `B`, `⌘B` or `Space`, or nil when nothing is bound.
    static func symbol(for command: EditorCommand, in keymap: Keymap? = nil) -> String? {
        (keymap ?? self.keymap).chords(for: command).first?.symbol
    }

    /// A tooltip: `Blade tool (B)`, or just the text when it has no key.
    static func help(_ text: String, _ command: EditorCommand, in keymap: Keymap? = nil) -> String {
        guard let symbol = symbol(for: command, in: keymap) else { return text }
        return "\(text) (\(symbol))"
    }

    /// Shows the command's key on a menu item.
    static func show(_ command: EditorCommand, on item: NSMenuItem, in keymap: Keymap? = nil) {
        guard let chord = (keymap ?? self.keymap).chords(for: command).first, let equivalent = chord.displayKeyEquivalent else { return }
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = equivalent.modifiers
    }
}
