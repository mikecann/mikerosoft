import AppKit
import SwiftUI

private struct ItemTopsKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PrompterView: View {
    @ObservedObject var model: PrompterModel
    var openSettings: () -> Void = {}

    private var settings: PrompterSettings { model.settings }

    var body: some View {
        GeometryReader { geometry in
            let readingY = geometry.size.height * settings.readingLine
            // Never let the margins squeeze the column below a third of the width.
            let margin = min(settings.sideMargin, geometry.size.width / 3)
            ZStack(alignment: .topLeading) {
                Color(hex: settings.backgroundColor, fallback: .black)

                if model.items.isEmpty {
                    EmptyScriptView(settings: settings)
                } else {
                    ScriptColumn(items: model.items, current: model.current, settings: settings)
                        .frame(
                            width: max(1, geometry.size.width - margin * 2),
                            alignment: .topLeading
                        )
                        .offset(x: margin, y: readingY - model.offset)
                        .onPreferenceChange(ItemTopsKey.self) { tops in
                            model.updateLayout(tops: tops, contentHeight: model.contentHeight)
                        }
                        .onPreferenceChange(ContentHeightKey.self) { height in
                            model.updateLayout(tops: model.tops, contentHeight: height)
                        }

                    // Fade text out under the drag handle.
                    LinearGradient(
                        colors: [Color(hex: settings.backgroundColor, fallback: .black), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 44)
                    .allowsHitTesting(false)

                    if settings.showReadingMarker {
                        ReadingMarker(color: Color(hex: settings.highlightColor, fallback: .yellow))
                            .offset(x: max(4, margin * 0.5 - 10), y: readingY - 12)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            // A beam-splitter prompter shows the screen through a mirror.
            .scaleEffect(x: settings.mirrorHorizontally ? -1 : 1, y: 1)
            .overlay(alignment: .top) {
                HandleBar(model: model, openSettings: openSettings)
            }
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip()
            }
        }
    }
}

private struct ScriptColumn: View {
    let items: [PromptItem]
    let current: Int?
    let settings: PrompterSettings

    var body: some View {
        VStack(alignment: .leading, spacing: settings.itemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                ItemView(item: item, state: state(of: index), settings: settings)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: ItemTopsKey.self,
                            value: [index: proxy.frame(in: .named("script")).minY]
                        )
                    })
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        })
        .coordinateSpace(name: "script")
    }

    private func state(of index: Int) -> ItemView.ReadState {
        guard let current else { return .upcoming }
        if index == current { return .current }
        return index < current ? .read : .upcoming
    }
}

private struct ItemView: View, Equatable {
    enum ReadState { case read, current, upcoming }

    let item: PromptItem
    let state: ReadState
    let settings: PrompterSettings

    private var textColor: Color { Color(hex: settings.textColor, fallback: .white) }
    private var highlight: Color { Color(hex: settings.highlightColor, fallback: .yellow) }
    private var fontSize: CGFloat { PrompterLayout.fontSize(for: item, settings: settings) }
    private var frameAlignment: Alignment { settings.alignment == .center ? .center : .leading }
    private var textAlignment: TextAlignment { settings.alignment == .center ? .center : .leading }

    private var opacity: Double {
        switch state {
        case .current: return 1
        case .upcoming: return settings.upcomingOpacity
        case .read: return settings.upcomingOpacity * 0.5
        }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.leading, PrompterLayout.indent(for: item, settings: settings))
            .animation(.easeOut(duration: 0.2), value: state)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .line:
            HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.35) {
                if item.depth > 0 {
                    Text("•").foregroundStyle(textColor.opacity(opacity * 0.6))
                }
                Text(item.text)
                    .foregroundStyle(textColor.opacity(opacity))
                    .multilineTextAlignment(textAlignment)
                    .lineSpacing(settings.lineSpacing)
            }
            .font(.system(size: fontSize, weight: state == .current ? .semibold : .medium, design: .rounded))
            .overlay(alignment: .leading) {
                if state == .current {
                    Capsule()
                        .fill(highlight)
                        .frame(width: 5)
                        .padding(.vertical, 4)
                        .offset(x: -18)
                }
            }

        case .heading:
            Text(item.text.uppercased())
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(highlight.opacity(0.75))
                .multilineTextAlignment(textAlignment)
                .padding(.top, settings.itemSpacing)

        case .cue:
            Label(item.text, systemImage: "hand.point.right.fill")
                .font(.system(size: fontSize, weight: .semibold, design: .rounded).italic())
                .foregroundStyle(highlight.opacity(0.7))
                .multilineTextAlignment(textAlignment)

        case .code:
            Text(item.text)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(textColor.opacity(0.55))
                .padding(fontSize * 0.5)
                .background(textColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct ReadingMarker: View {
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 14, y: 12))
            path.addLine(to: CGPoint(x: 0, y: 24))
            path.closeSubpath()
        }
        .fill(color)
        .frame(width: 14, height: 24)
    }
}

private struct EmptyScriptView: View {
    let settings: PrompterSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 44))
            Text("Paste your notes")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("⌘V pastes the clipboard. Click, Space or → for the next line.")
                .font(.system(size: 17, design: .rounded))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(hex: settings.textColor).opacity(0.6))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The small pill at the top: drag it to move the window. Hovering shows
/// play/pause, the position, and a settings button.
private struct HandleBar: View {
    @ObservedObject var model: PrompterModel
    let openSettings: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if hovering {
                Button(action: model.toggleScrolling) {
                    Image(systemName: model.isScrolling ? "pause.fill" : "play.fill")
                }
                .help(model.isScrolling ? "Pause auto-scroll (P)" : "Auto-scroll (P)")
                if let position = model.position {
                    Text("\(position)/\(model.stopCount)")
                        .monospacedDigit()
                }
            }
            Capsule()
                .fill(.white.opacity(hovering ? 0.8 : 0.3))
                .frame(width: 44, height: 5)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .background(WindowDragArea())
                .help("Drag to move")
            if hovering {
                Button(action: openSettings) {
                    Image(systemName: "gearshape.fill")
                }
                .help("Settings (⌘,)")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, hovering ? 12 : 0)
        .background {
            if hovering { Capsule().fill(.black.opacity(0.6)) }
        }
        .padding(.top, 6)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// An AppKit view that starts a native window drag, so the borderless window
/// moves only from the handle and clicks elsewhere still advance the script.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Bottom-right corner grip for resizing the borderless window.
private struct ResizeGrip: View {
    @State private var hovering = false

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.15))
            .frame(width: 24, height: 24)
            .background(WindowResizeArea())
            .onHover { hovering = $0 }
    }
}

private struct WindowResizeArea: NSViewRepresentable {
    final class ResizeView: NSView {
        private var startMouse: NSPoint = .zero
        private var startFrame: NSRect = .zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startFrame = window?.frame ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let mouse = NSEvent.mouseLocation
            let minSize = window.minSize
            let width = max(minSize.width, startFrame.width + mouse.x - startMouse.x)
            let height = max(minSize.height, startFrame.height - (mouse.y - startMouse.y))
            // AppKit's origin is bottom-left, so keep the top edge fixed.
            window.setFrame(
                NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height),
                display: true
            )
        }
    }

    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ nsView: ResizeView, context: Context) {}
}
