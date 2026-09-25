import AppKit

/// Replays mouse gestures into a window through the same `mouseDown`,
/// `mouseDragged` and `mouseUp` calls AppKit makes, so smoke tests and
/// agents can drive the timeline and viewer without screen control:
///
///     open -g "tandem://simulate?drag=600,700,700,700&mods=cmd"
///     open -g "tandem://simulate?menu=600,700&out=/tmp/menu.txt"
///
/// Points are in window coordinates measured from the top left.
@MainActor
enum InputSimulator {
    struct Gesture: Equatable {
        enum Kind: Equatable {
            case click(count: Int)
            case drag(to: CGPoint, steps: Int)
            /// Lists the context menu's items into a file instead of showing it.
            case menu(out: String)
            case scroll(dx: CGFloat, dy: CGFloat)
        }
        var kind: Kind
        var at: CGPoint
        var modifiers: NSEvent.ModifierFlags
    }

    nonisolated static func parse(_ query: [String: String]) -> Gesture? {
        func numbers(_ text: String?) -> [CGFloat] {
            (text ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
        }
        var flags: NSEvent.ModifierFlags = []
        for name in (query["mods"] ?? "").split(separator: ",") {
            switch name {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        let drag = numbers(query["drag"])
        if drag.count == 4 {
            let steps = Int(query["steps"] ?? "") ?? 12
            return Gesture(kind: .drag(to: CGPoint(x: drag[2], y: drag[3]), steps: max(1, steps)), at: CGPoint(x: drag[0], y: drag[1]), modifiers: flags)
        }
        let click = numbers(query["click"])
        if click.count == 2 {
            return Gesture(kind: .click(count: Int(query["count"] ?? "") ?? 1), at: CGPoint(x: click[0], y: click[1]), modifiers: flags)
        }
        let menu = numbers(query["menu"])
        if menu.count == 2, let out = query["out"] {
            return Gesture(kind: .menu(out: NSString(string: out).expandingTildeInPath), at: CGPoint(x: menu[0], y: menu[1]), modifiers: flags)
        }
        let scroll = numbers(query["scroll"])
        if scroll.count == 4 {
            return Gesture(kind: .scroll(dx: scroll[2], dy: scroll[3]), at: CGPoint(x: scroll[0], y: scroll[1]), modifiers: flags)
        }
        return nil
    }

    static func run(_ gesture: Gesture, in window: NSWindow) {
        guard let frame = window.contentView?.superview ?? window.contentView else { return }
        func windowPoint(_ point: CGPoint) -> NSPoint {
            NSPoint(x: point.x, y: frame.bounds.height - point.y)
        }
        let start = windowPoint(gesture.at)
        guard let target = frame.hitTest(frame.convert(start, from: nil)) else { return }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: gesture.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )
        }
        switch gesture.kind {
        case .click(let count):
            for click in 1...max(1, count) {
                if let down = mouse(.leftMouseDown, start, clicks: click) { target.mouseDown(with: down) }
                if let up = mouse(.leftMouseUp, start, clicks: click) { target.mouseUp(with: up) }
            }
        case .drag(let to, let steps):
            let end = windowPoint(to)
            if let down = mouse(.leftMouseDown, start) { target.mouseDown(with: down) }
            for step in 1...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                if let drag = mouse(.leftMouseDragged, point) { target.mouseDragged(with: drag) }
            }
            if let up = mouse(.leftMouseUp, end) { target.mouseUp(with: up) }
        case .menu(let out):
            guard let event = mouse(.rightMouseDown, start) else { return }
            let menu = target.menu(for: event)
            try? describe(menu).write(toFile: out, atomically: true, encoding: .utf8)
        case .scroll(let dx, let dy):
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
            cgEvent.location = CGPoint(x: window.frame.minX + start.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.minY + start.y))
            cgEvent.flags = CGEventFlags(rawValue: UInt64(gesture.modifiers.rawValue))
            if let event = NSEvent(cgEvent: cgEvent) { target.scrollWheel(with: event) }
        }
    }

    /// The menu's items, one per line, indented for submenus, with ✓ for
    /// checked items and (off) for disabled ones.
    static func describe(_ menu: NSMenu?, depth: Int = 0) -> String {
        guard let menu else { return "(no menu)" }
        var lines: [String] = []
        for item in menu.items {
            if item.isSeparatorItem {
                lines.append(String(repeating: "  ", count: depth) + "---")
                continue
            }
            let mark = item.state == .on ? "✓ " : ""
            let off = item.isEnabled ? "" : " (off)"
            lines.append(String(repeating: "  ", count: depth) + mark + item.title + off)
            if let submenu = item.submenu { lines.append(describe(submenu, depth: depth + 1)) }
        }
        return lines.joined(separator: "\n")
    }
}
