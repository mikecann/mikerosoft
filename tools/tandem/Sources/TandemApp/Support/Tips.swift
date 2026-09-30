import AppKit
import SwiftUI

/// Tandem's own tooltips. macOS's (SwiftUI's `.help`) never showed in the
/// editor: the text was on every control, where VoiceOver could read it,
/// but hovering brought nothing up, and Mike couldn't tell what the
/// timeline's tool buttons did or which keys they had. These only need
/// the pointer's hover, which the window gets: rest on a control for half
/// a second and its words show beside the pointer, in the window, until
/// the pointer leaves, clicks, types or scrolls.
///
/// `.tip(_:)` on a control, and `.tipLayer()` on a window's root view to
/// draw them.
@MainActor
@Observable
final class TipCenter {
    static let shared = TipCenter()

    /// The tip showing, the window it's in and where the pointer was, in
    /// the window's top-left points.
    private(set) var shown: (text: String, window: ObjectIdentifier, at: CGPoint)?

    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var pointer: CGPoint = .zero
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var monitor: Any?
    /// As long as macOS's own tooltips take to come up.
    static let delay: TimeInterval = 0.5

    /// The pointer is on a control with `text`, at `point` in its window's
    /// top-left points (SwiftUI's global space).
    func hover(_ text: String, owner: UUID, at point: CGPoint) {
        pointer = point
        guard self.owner != owner else { return }
        installMonitor()
        self.owner = owner
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.show(text, owner: owner) }
        }
        pending = work
        // Moving from one control to the next while a tip shows swaps it
        // straight away, as macOS's do.
        DispatchQueue.main.asyncAfter(deadline: .now() + (shown == nil ? Self.delay : 0.05), execute: work)
    }

    /// The pointer left the control. Another control may have taken over.
    func leave(owner: UUID) {
        guard self.owner == owner else { return }
        hide()
    }

    func hide() {
        pending?.cancel()
        pending = nil
        owner = nil
        if shown != nil { shown = nil }
    }

    private func show(_ text: String, owner: UUID) {
        // The window being hovered is the key one; a window behind it gets
        // no tips, as with macOS's.
        guard self.owner == owner, let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first(where: \.isVisible) else { return }
        shown = (text, ObjectIdentifier(window), pointer)
    }

    /// A click, a key or a scroll puts the tip away, as macOS's do.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { TipCenter.shared.hide() }
            return event
        }
    }
}

/// Where a tip sits beside the pointer: below and to the right, flipped
/// left or above near the window's edges so it stays whole.
enum TipPlacement {
    static let gap = CGSize(width: 12, height: 20)

    /// The tip's top-left corner for a tip `size` at pointer `at` in a
    /// window `bounds` big.
    static func origin(size: CGSize, at point: CGPoint, in bounds: CGSize) -> CGPoint {
        var x = point.x + gap.width
        var y = point.y + gap.height
        if x + size.width > bounds.width - 6 { x = max(6, point.x - size.width - 6) }
        if y + size.height > bounds.height - 6 { y = max(6, point.y - size.height - 8) }
        return CGPoint(x: x, y: y)
    }
}

private struct TipModifier: ViewModifier {
    let text: String?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content
                // VoiceOver still reads it, as it read `.help`.
                .accessibilityHint(text)
                .onContinuousHover(coordinateSpace: .global) { phase in
                    switch phase {
                    case .active(let point): TipCenter.shared.hover(text, owner: id, at: point)
                    case .ended: TipCenter.shared.leave(owner: id)
                    }
                }
                .onDisappear { TipCenter.shared.leave(owner: id) }
        } else {
            content
        }
    }
}

/// Draws the tip for the window it's in.
private struct TipLayer: View {
    @State private var window: ObjectIdentifier?
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            if let shown = TipCenter.shared.shown, shown.window == window {
                let origin = TipPlacement.origin(size: size, at: shown.at, in: geometry.size)
                Text(verbatim: shown.text)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised.color))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.controlBorder.color, lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .offset(x: origin.x, y: origin.y)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background(WindowReader(window: $window))
        .allowsHitTesting(false)
    }
}

/// Reports the window a view is in. Its identity, not its number: a
/// window has no number until it's on screen, and the root view is built
/// before that.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: ObjectIdentifier?

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.report = { window = $0 }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var report: ((ObjectIdentifier?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let id = window.map(ObjectIdentifier.init)
            DispatchQueue.main.async { [weak self] in self?.report?(id) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// What the control does (and its key), shown after half a second's
    /// hover. Tandem's replacement for `.help`, which never showed.
    func tip(_ text: String) -> some View {
        modifier(TipModifier(text: text))
    }

    func tip(ifAny text: String?) -> some View {
        modifier(TipModifier(text: text))
    }

    /// Draws the tips for this window, over everything else in it.
    func tipLayer() -> some View {
        overlay { TipLayer() }
    }
}
