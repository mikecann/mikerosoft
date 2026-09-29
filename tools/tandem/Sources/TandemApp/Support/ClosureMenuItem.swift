import AppKit

/// A menu item that runs a closure, for context menus built on the fly.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run(_:)) : nil, keyEquivalent: "")
        self.target = self
        self.state = state
        self.isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run(_ sender: Any?) {
        handler()
    }
}

extension NSMenu {
    /// Adds an item that runs `handler`, with an icon (an SF Symbol from
    /// `Icons`) and, when it does what a keymap command does, that
    /// command's key shown beside it, so menus teach the shortcuts.
    @discardableResult
    func add(_ title: String, icon: String? = nil, command: EditorCommand? = nil, enabled: Bool = true, checked: Bool = false, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, enabled: enabled, state: checked ? .on : .off, handler: handler)
        if let icon = icon ?? command.flatMap(Icons.command) { item.image = Icons.menuImage(icon) }
        if let command { MainActor.assumeIsolated { Shortcuts.show(command, on: item) } }
        addItem(item)
        return item
    }

    func addSubmenu(_ title: String, icon: String? = nil, build: (NSMenu) -> Void) {
        let menu = NSMenu(title: title)
        build(menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let icon { item.image = Icons.menuImage(icon) }
        item.submenu = menu
        addItem(item)
    }
}
