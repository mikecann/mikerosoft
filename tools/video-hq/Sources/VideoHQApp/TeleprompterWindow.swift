import AppKit
import SwiftUI

enum TeleprompterWindowPlacement {
    // The taskbar is configured to 31.7 points on this Mac. Reserve a rounded
    // 32-point strip so its reveal area never overlaps the Prompter window.
    static let taskbarReservation: CGFloat = 32
    static let windowLevel: NSWindow.Level = .normal

    static let styleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
    ]

    static func isPrompterDisplay(named name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("elgato") && normalized.contains("prom")
    }

    static func windowFrame(in screenFrame: CGRect) -> CGRect {
        let reservation = min(taskbarReservation, max(0, screenFrame.height - 240))
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY + reservation,
            width: screenFrame.width,
            height: screenFrame.height - reservation
        )
    }
}

enum TeleprompterScriptBlock: Equatable {
    case spoken(String)
    case code(language: String, text: String)
    case callout(String)
    case space
}

enum TeleprompterLayout {
    static let paragraphSpacing: CGFloat = 44
    static let spokenLineSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 160
    static let explicitBlankHeight: CGFloat = 12
}

enum TeleprompterParagraphNavigator {
    static func spokenIndices(in blocks: [TeleprompterScriptBlock]) -> [Int] {
        blocks.indices.filter { index in
            if case .spoken = blocks[index] { return true }
            return false
        }
    }

    static func nextIndex(
        after currentIndex: Int?,
        in blocks: [TeleprompterScriptBlock]
    ) -> Int? {
        let indices = spokenIndices(in: blocks)
        guard let first = indices.first else { return nil }
        guard let currentIndex else { return first }
        return indices.first(where: { $0 > currentIndex }) ?? indices.last
    }

    static func previousIndex(
        before currentIndex: Int?,
        in blocks: [TeleprompterScriptBlock]
    ) -> Int? {
        let indices = spokenIndices(in: blocks)
        guard let first = indices.first else { return nil }
        guard let currentIndex else { return first }
        return indices.last(where: { $0 < currentIndex }) ?? first
    }
}

enum TeleprompterScriptParser {
    static func parse(_ script: String) -> [TeleprompterScriptBlock] {
        let lines = scriptSection(in: script).components(separatedBy: .newlines)
        var blocks: [TeleprompterScriptBlock] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(
                    language: language,
                    text: codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            } else if trimmed.hasPrefix("<callout") {
                var calloutLines: [String] = []
                index += 1
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces) != "</callout>" {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { calloutLines.append(line) }
                    index += 1
                }
                blocks.append(.callout(calloutLines.joined(separator: "\n")))
            } else if trimmed == "<empty-block/>" {
                appendSpace(to: &blocks)
            } else if trimmed.isEmpty {
                appendSpace(to: &blocks)
            } else {
                blocks.append(.spoken(trimmed))
            }

            index += 1
        }

        while blocks.last == .space { blocks.removeLast() }
        return blocks
    }

    private static func scriptSection(in document: String) -> String {
        let lines = document.components(separatedBy: .newlines)
        guard let headingIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "# script"
        }) else {
            // Plain text scripts and older files without section headings should
            // remain useful instead of producing an empty Prompter window.
            return document
        }

        let contentStart = lines.index(after: headingIndex)
        let contentEnd = lines[contentStart...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
        }) ?? lines.endIndex
        return lines[contentStart..<contentEnd].joined(separator: "\n")
    }

    private static func appendSpace(to blocks: inout [TeleprompterScriptBlock]) {
        guard !blocks.isEmpty, blocks.last != .space else { return }
        blocks.append(.space)
    }
}

private final class TeleprompterWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape always gives you a quick way back to Video HQ.
            orderOut(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

// SwiftUI's tap gesture handles primary clicks but does not expose the mouse
// button on macOS. This background view observes secondary clicks without
// sitting on top of the ScrollView and blocking normal scrolling.
private final class TeleprompterRightClickMonitorView: NSView {
    var action: () -> Void = {}
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()

        guard let window else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self, weak window] event in
            guard let self, event.window === window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            self.action()
            return nil
        }
    }

    fileprivate func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }
}

private struct TeleprompterRightClickMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> TeleprompterRightClickMonitorView {
        let view = TeleprompterRightClickMonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: TeleprompterRightClickMonitorView, context: Context) {
        nsView.action = action
    }

    static func dismantleNSView(
        _ nsView: TeleprompterRightClickMonitorView,
        coordinator: Void
    ) {
        nsView.stopMonitoring()
    }
}

private struct TeleprompterScriptView: View {
    private let blocks: [TeleprompterScriptBlock]
    @State private var currentParagraphIndex: Int?

    init(script: String) {
        blocks = TeleprompterScriptParser.parse(script)
        currentParagraphIndex = nil
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: TeleprompterLayout.paragraphSpacing) {
                        // This scroll runway lets even the very first paragraph
                        // move down to the camera-height reading position.
                        Color.clear.frame(height: geometry.size.height)

                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            blockView(block)
                                .id(index)
                        }
                    }
                    // A narrow reading column keeps the words near the camera lens
                    // instead of making the reader's eyes travel across the display.
                    .padding(.horizontal, TeleprompterLayout.horizontalPadding)
                    .padding(.vertical, 52)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    advanceParagraph(using: proxy, animated: true)
                }
                .background {
                    TeleprompterRightClickMonitor {
                        retreatParagraph(using: proxy)
                    }
                }
                .onAppear {
                    // Wait until SwiftUI has measured the runway before positioning
                    // the opening paragraph at the bottom of the Prompter.
                    DispatchQueue.main.async {
                        advanceParagraph(using: proxy, animated: false)
                    }
                }
            }
        }
        .background(Color.black)
    }

    private func advanceParagraph(using proxy: ScrollViewProxy, animated: Bool) {
        guard let nextIndex = TeleprompterParagraphNavigator.nextIndex(
            after: currentParagraphIndex,
            in: blocks
        ) else { return }

        currentParagraphIndex = nextIndex
        let scroll = { proxy.scrollTo(nextIndex, anchor: .bottom) }
        if animated {
            withAnimation(.easeInOut(duration: 0.35), scroll)
        } else {
            scroll()
        }
    }

    private func retreatParagraph(using proxy: ScrollViewProxy) {
        guard let previousIndex = TeleprompterParagraphNavigator.previousIndex(
            before: currentParagraphIndex,
            in: blocks
        ) else { return }

        currentParagraphIndex = previousIndex
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(previousIndex, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func blockView(_ block: TeleprompterScriptBlock) -> some View {
        switch block {
        case .spoken(let text):
            Text(text)
                .font(.system(size: 46, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .lineSpacing(TeleprompterLayout.spokenLineSpacing)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)

        case .code(let language, let text):
            VStack(spacing: 8) {
                if !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(size: 23, weight: .regular, design: .monospaced))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }

        case .callout(let text):
            HStack(spacing: 14) {
                Image(systemName: "lightbulb.fill")
                Text(text)
                    .multilineTextAlignment(.center)
            }
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.yellow.opacity(0.82))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(Color.yellow.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))

        case .space:
            Color.clear.frame(height: TeleprompterLayout.explicitBlankHeight)
        }
    }
}

@MainActor
final class TeleprompterWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(script: String, projectName: String) {
        let window = window ?? makeWindow()
        window.title = "Teleprompter - \(projectName)"
        window.contentView = NSHostingView(rootView: TeleprompterScriptView(script: script))

        let screen = NSScreen.screens.first {
            TeleprompterWindowPlacement.isPrompterDisplay(named: $0.localizedName)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        window.setFrame(
            TeleprompterWindowPlacement.windowFrame(in: screen.visibleFrame),
            display: true
        )
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
    }

    private func makeWindow() -> NSWindow {
        let window = TeleprompterWindow(
            contentRect: .zero,
            styleMask: TeleprompterWindowPlacement.styleMask,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Respect normal macOS z-order so overlays such as the user's taskbar
        // remain visible above the teleprompter when they are designed to.
        window.level = TeleprompterWindowPlacement.windowLevel
        window.hasShadow = true
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.delegate = self
        return window
    }
}
