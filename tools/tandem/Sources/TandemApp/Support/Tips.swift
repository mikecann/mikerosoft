import AppKit
import SwiftUI

/// Tooltips for SwiftUI controls, as macOS's own AppKit ones.
///
/// SwiftUI's `.help` never showed in the editor window, and SwiftUI's
/// hover didn't reach the controls either: the words were on every
/// control (VoiceOver read them) but hovering brought nothing up, and Mike
/// couldn't tell what the timeline's tool buttons did or which keys they
/// had. A plain AppKit view's `toolTip` does show there (the timeline's
/// "+ Track" corner has one), so each control gets a see-through AppKit
/// view over it carrying its tooltip. It lets every click, drag and scroll
/// through to the control, and macOS shows the tooltip after its usual
/// delay, in its usual look.
extension View {
    /// What the control does (and its key), as a tooltip.
    func tip(_ text: String) -> some View {
        modifier(TipModifier(text: text))
    }

    func tip(ifAny text: String?) -> some View {
        modifier(TipModifier(text: text))
    }
}

private struct TipModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content
                // VoiceOver still reads it, as it read `.help`.
                .accessibilityHint(text)
                .overlay(TipAnchor(text: text).accessibilityHidden(true))
        } else {
            content
        }
    }
}

/// A see-through AppKit view with a tooltip. It's never the target of a
/// click (hit testing passes through it), but its tooltip area still
/// follows the pointer, which is all macOS needs to show the tooltip.
struct TipAnchor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TipAnchorView {
        let view = TipAnchorView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: TipAnchorView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }
}

final class TipAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
