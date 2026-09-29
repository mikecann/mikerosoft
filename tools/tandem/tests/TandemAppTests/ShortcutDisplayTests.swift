import AppKit
import XCTest
@testable import TandemApp

@MainActor
final class ShortcutDisplayTests: XCTestCase {
    private let keymap = Keymap(name: "Test", bindings: [
        KeyChord("b")!: .toolBlade,
        KeyChord("cmd+b")!: .bladeAtPlayhead,
        KeyChord("shift+delete")!: .rippleDelete
    ])

    func testTooltipsNameTheKey() {
        XCTAssertEqual(Shortcuts.help("Blade tool", .toolBlade, in: keymap), "Blade tool (B)")
        XCTAssertEqual(Shortcuts.help("Ripple delete", .rippleDelete, in: keymap), "Ripple delete (⇧⌫)")
        XCTAssertEqual(Shortcuts.help("Zoom in", .zoomIn, in: keymap), "Zoom in", "no key, no brackets")
    }

    /// Menus show plain keys as well as Command ones.
    func testMenusShowPlainKeys() {
        let plain = KeyChord("b")!
        XCTAssertNil(plain.menuKeyEquivalent)
        XCTAssertEqual(plain.displayKeyEquivalent?.key, "b")
        XCTAssertEqual(plain.displayKeyEquivalent?.modifiers, [])
        let item = NSMenuItem(title: "Blade tool", action: nil, keyEquivalent: "")
        Shortcuts.show(.rippleDelete, on: item, in: keymap)
        XCTAssertEqual(item.keyEquivalent, "\u{8}")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.shift])
    }

    /// The menu bar shows B but leaves the key to the window, where the
    /// keyboard router runs it, or a text field types it. Command keys
    /// still go through the menu.
    func testMenuBarLeavesPlainKeysToTheWindow() throws {
        _ = NSApplication.shared
        var ran: [String] = []
        let root = EditorMainMenu()
        let tools = NSMenu(title: "Tools")
        let blade = ClosureMenuItem("Blade tool") { ran.append("tool") }
        blade.keyEquivalent = "b"
        blade.keyEquivalentModifierMask = []
        tools.addItem(blade)
        let cut = ClosureMenuItem("Blade at playhead") { ran.append("cut") }
        cut.keyEquivalent = "b"
        cut.keyEquivalentModifierMask = [.command]
        tools.addItem(cut)
        let holder = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        holder.submenu = tools
        root.addItem(holder)

        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11
            ))
        }
        XCTAssertFalse(root.performKeyEquivalent(with: try key([])))
        XCTAssertTrue(root.performKeyEquivalent(with: try key([.command])))
        XCTAssertEqual(ran, ["cut"])
    }
}
