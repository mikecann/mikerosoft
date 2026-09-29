import AppKit
import SwiftUI

/// Makes the empty parts of a SwiftUI bar move the window, as a title bar
/// does. It sits behind the bar's buttons and tabs, so they keep their
/// clicks; text over it should opt out of hit testing so it drags too.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    /// Where a scripted drag started, in window coordinates, and where the
    /// window was.
    private var scripted: (mouse: NSPoint, origin: NSPoint)?

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            TitleBarDoubleClick.perform(TitleBarDoubleClick.action(), on: window)
            return
        }
        if InputSimulator.isReplaying {
            // A scripted drag has no real mouse for the window server to
            // follow, so it moves the window by hand.
            scripted = (event.locationInWindow, window.frame.origin)
            return
        }
        // The window server moves the window, with snapping and tiling,
        // until the button comes up.
        window.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scripted, let window else { return }
        window.setFrameOrigin(NSPoint(
            x: scripted.origin.x + event.locationInWindow.x - scripted.mouse.x,
            y: scripted.origin.y + event.locationInWindow.y - scripted.mouse.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        scripted = nil
    }
}

/// Double-clicking a title bar does what System Settings says: zoom (fill),
/// minimise, or nothing.
enum TitleBarDoubleClick {
    enum Action: Equatable {
        case zoom, minimize, none
    }

    /// From the `AppleActionOnDoubleClick` preference.
    static func action(_ preference: String? = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) -> Action {
        switch preference?.lowercased() {
        case "minimize": return .minimize
        case "none": return .none
        default: return .zoom
        }
    }

    static func perform(_ action: Action, on window: NSWindow) {
        switch action {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }
}
