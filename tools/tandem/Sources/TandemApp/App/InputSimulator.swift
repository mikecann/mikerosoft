import AppKit
import SwiftUI

/// Any SwiftUI hosting view, whatever its root.
private protocol NSHostingViewMarker {}
extension NSHostingView: NSHostingViewMarker {}

/// Replays mouse gestures into a window through the same `mouseDown`,
/// `mouseDragged` and `mouseUp` calls AppKit makes, so smoke tests and
/// agents can drive the timeline and viewer without screen control:
///
///     open -g "tandem://simulate?drag=600,700,700,700&mods=cmd"
///     open -g "tandem://simulate?menu=600,700&out=/tmp/menu.txt"
///     open -g "tandem://simulate?drop=tandem-effect:vignette&at=600,700"
///
/// A drop hands a library payload (see `LibraryDrag`) to the drop target
/// under the point, as if it had been dragged there from a library tab.
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
            /// Picks an item from the context menu by its title, as if
            /// clicked. Items in submenus are found too.
            case choose(String)
            case scroll(dx: CGFloat, dy: CGFloat)
            case drop(payload: String)
            /// Files dropped as if from Finder.
            case dropFiles([String])
            /// Moves the pointer to the point and leaves it there, for
            /// hover previews.
            case hover
            /// Types into whatever has the keys; a newline presses Return.
            case type(String)
        }
        var kind: Kind
        var at: CGPoint
        var modifiers: NSEvent.ModifierFlags
        /// A plain key held during the gesture, like Z for zoom rectangles.
        var heldKey: String? = nil
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
            return Gesture(kind: .drag(to: CGPoint(x: drag[2], y: drag[3]), steps: max(1, steps)), at: CGPoint(x: drag[0], y: drag[1]), modifiers: flags, heldKey: query["hold"])
        }
        let click = numbers(query["click"])
        if click.count == 2 {
            return Gesture(kind: .click(count: Int(query["count"] ?? "") ?? 1), at: CGPoint(x: click[0], y: click[1]), modifiers: flags)
        }
        let menu = numbers(query["menu"])
        // The menu's items go to a text file, and only a text file: links
        // can come from anywhere.
        if menu.count == 2, let out = query["out"].map({ NSString(string: $0).expandingTildeInPath }),
           out.hasPrefix("/"), URL(fileURLWithPath: out).pathExtension.lowercased() == "txt" {
            return Gesture(kind: .menu(out: out), at: CGPoint(x: menu[0], y: menu[1]), modifiers: flags)
        }
        if menu.count == 2, let title = query["choose"], !title.isEmpty {
            return Gesture(kind: .choose(title), at: CGPoint(x: menu[0], y: menu[1]), modifiers: flags)
        }
        let scroll = numbers(query["scroll"])
        if scroll.count == 4 {
            return Gesture(kind: .scroll(dx: scroll[2], dy: scroll[3]), at: CGPoint(x: scroll[0], y: scroll[1]), modifiers: flags)
        }
        if let text = query["type"], !text.isEmpty {
            return Gesture(kind: .type(text), at: .zero, modifiers: flags)
        }
        let hover = numbers(query["hover"])
        if hover.count == 2 {
            return Gesture(kind: .hover, at: CGPoint(x: hover[0], y: hover[1]), modifiers: flags)
        }
        let at = numbers(query["at"])
        if let payload = query["drop"], at.count == 2, LibraryDrag.parse(payload) != nil {
            return Gesture(kind: .drop(payload: payload), at: CGPoint(x: at[0], y: at[1]), modifiers: flags)
        }
        if let files = query["files"], at.count == 2 {
            let paths = files.split(separator: ",").map { NSString(string: String($0)).expandingTildeInPath }.filter { $0.hasPrefix("/") }
            if !paths.isEmpty { return Gesture(kind: .dropFiles(paths), at: CGPoint(x: at[0], y: at[1]), modifiers: flags) }
        }
        return nil
    }

    /// True while a gesture is being replayed, for views that would hand
    /// a real mouse to the window server (window drags).
    static private(set) var isReplaying = false

    static func run(_ gesture: Gesture, in window: NSWindow) {
        guard let frame = window.contentView?.superview ?? window.contentView else { return }
        isReplaying = true
        defer { isReplaying = false }
        func windowPoint(_ point: CGPoint) -> NSPoint {
            NSPoint(x: point.x, y: frame.bounds.height - point.y)
        }
        if case .type(let text) = gesture.kind {
            // Typing goes to the first responder, not the view under a point.
            guard let responder = window.firstResponder else { return }
            for part in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if part.offset > 0 { responder.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
                if !part.element.isEmpty { responder.insertText(String(part.element)) }
            }
            return
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
        case .choose(let title):
            guard let event = mouse(.rightMouseDown, start), let menu = target.menu(for: event) else { return }
            func pick(in menu: NSMenu) -> Bool {
                for (index, item) in menu.items.enumerated() {
                    if item.title == title, item.isEnabled, item.submenu == nil {
                        menu.performActionForItem(at: index)
                        return true
                    }
                    if let submenu = item.submenu, pick(in: submenu) { return true }
                }
                return false
            }
            if !pick(in: menu) { NSLog("Tandem: no enabled menu item called %@", title) }
        case .scroll(let dx, let dy):
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
            cgEvent.location = CGPoint(x: window.frame.minX + start.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.minY + start.y))
            cgEvent.flags = CGEventFlags(rawValue: UInt64(gesture.modifiers.rawValue))
            if let event = NSEvent(cgEvent: cgEvent) { target.scrollWheel(with: event) }
        case .hover:
            // Tracking areas (and SwiftUI's hover) hear about the pointer
            // from the view under it, not from the window.
            guard let moved = mouse(.mouseMoved, start) else { return }
            var view: NSView? = target
            while let current = view {
                current.mouseEntered(with: moved)
                current.mouseMoved(with: moved)
                if current is NSHostingViewMarker { break }
                view = current.superview
            }
        case .type:
            break
        case .drop, .dropFiles:
            // The nearest view up the chain that takes drops.
            var view: NSView? = target
            while let candidate = view, candidate.registeredDraggedTypes.isEmpty { view = candidate.superview }
            guard let destination = view else { return }
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mikerosoft.tandem.simulated-drop"))
            pasteboard.clearContents()
            if case .drop(let payload) = gesture.kind {
                pasteboard.setString(payload, forType: .string)
            } else if case .dropFiles(let paths) = gesture.kind {
                pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
            }
            let info = SimulatedDrop(window: window, location: start, pasteboard: pasteboard)
            if destination.draggingEntered(info) != [], destination.draggingUpdated(info) != [], destination.prepareForDragOperation(info), destination.performDragOperation(info) {
                destination.concludeDragOperation(info)
            } else {
                destination.draggingExited(info)
            }
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

/// Just enough of a drag for a drop target to read: where it is and what
/// it carries.
@MainActor
private final class SimulatedDrop: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingPasteboard = pasteboard
    }

    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    /// SwiftUI's drop targets read the dragged items this way.
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        let objects = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop: ObjCBool = false
        for (index, object) in objects.enumerated() {
            guard let writer = object as? NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
}
