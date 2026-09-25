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
    @discardableResult
    func add(_ title: String, enabled: Bool = true, checked: Bool = false, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, enabled: enabled, state: checked ? .on : .off, handler: handler)
        addItem(item)
        return item
    }

    func addSubmenu(_ title: String, build: (NSMenu) -> Void) {
        let menu = NSMenu(title: title)
        build(menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        addItem(item)
    }
}
