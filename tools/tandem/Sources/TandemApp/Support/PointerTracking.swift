import AppKit
import SwiftUI

/// Hover for SwiftUI views, from AppKit.
///
/// SwiftUI's own hover (`onHover`, `onContinuousHover`, `.help`) never
/// fires in Tandem's editor window, so nothing lit up under the pointer:
/// no button backgrounds, no tile outlines, no scrubbing a sound by
/// hovering it. AppKit's tracking areas work there (the timeline is built
/// on them), so these put a see-through AppKit view over the SwiftUI view
/// that follows the pointer and says so. It never takes a click: hit
/// testing passes through it to the view underneath.
extension View {
    /// Like `onHover`: true when the pointer comes onto the view, false when
    /// it leaves.
    func pointerHover(_ action: @escaping (Bool) -> Void) -> some View {
        overlay(PointerTracker(onHover: action, onMove: nil))
    }

    /// Like `onContinuousHover`: where the pointer is in the view, in its
    /// top-left points, and nil when it leaves.
    func pointerMoves(_ action: @escaping (CGPoint?) -> Void) -> some View {
        overlay(PointerTracker(onHover: nil, onMove: action))
    }

    /// A background that shows while the pointer is over the view, for
    /// buttons that should answer the pointer.
    func hoverBackground(_ color: Color = Theme.tabSelected.color, cornerRadius: CGFloat = 5, when enabled: Bool = true) -> some View {
        modifier(HoverBackground(color: color, cornerRadius: cornerRadius, enabled: enabled))
    }
}

private struct HoverBackground: ViewModifier {
    let color: Color
    let cornerRadius: CGFloat
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(enabled && hovering ? color : .clear))
            .pointerHover { hovering = $0 }
    }
}

struct PointerTracker: NSViewRepresentable {
    var onHover: ((Bool) -> Void)?
    var onMove: ((CGPoint?) -> Void)?

    func makeNSView(context: Context) -> PointerTrackerView {
        let view = PointerTrackerView()
        view.onHover = onHover
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: PointerTrackerView, context: Context) {
        view.onHover = onHover
        view.onMove = onMove
    }
}

final class PointerTrackerView: NSView {
    var onHover: ((Bool) -> Void)?
    var onMove: ((CGPoint?) -> Void)? {
        didSet { if (onMove == nil) != (oldValue == nil) { updateTrackingAreas() } }
    }
    private var area: NSTrackingArea?
    private(set) var inside = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if onMove != nil { options.insert(.mouseMoved) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        inside = true
        onHover?(true)
        onMove?(point(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        onMove?(point(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        leave()
    }

    /// A view that goes away with the pointer on it (a row scrolled off, a
    /// tab switched) says the pointer left.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { leave() }
    }

    private func leave() {
        guard inside else { return }
        inside = false
        onHover?(false)
        onMove?(nil)
    }

    private func point(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
