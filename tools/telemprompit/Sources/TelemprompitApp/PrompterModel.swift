import AppKit
import SwiftUI

/// The script, the reader's position, and the settings. The prompter view
/// reports where each item was laid out; the model turns navigation into a
/// scroll offset, which is the content position that sits on the reading line.
@MainActor
final class PrompterModel: ObservableObject {
    @Published var scriptText = "" {
        didSet {
            guard scriptText != oldValue else { return }
            items = ScriptParser.parse(scriptText)
            if let current, current < items.count, items[current].kind == .line {
                return
            }
            current = PromptNavigator.stop(atOffset: offset, tops: tops, in: items)
        }
    }

    @Published private(set) var items: [PromptItem] = []
    @Published private(set) var current: Int?
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isScrolling = false
    @Published var settings: PrompterSettings {
        didSet {
            let clamped = settings.clamped()
            if clamped != settings { settings = clamped; return }
            PrompterSettings.save(settings, to: defaults)
        }
    }

    private(set) var tops: [Int: CGFloat] = [:]
    private(set) var contentHeight: CGFloat = 0
    private let defaults: UserDefaults
    private var scrollTimer: Timer?
    private var lastTick: CFTimeInterval = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = PrompterSettings.load(from: defaults)
    }

    // MARK: - Script

    func load(_ text: String) {
        stopScrolling()
        scriptText = text
        current = PromptNavigator.first(in: items)
        anchorToCurrent(animated: false)
    }

    @discardableResult
    func pasteFromClipboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        load(text)
        return true
    }

    var stopCount: Int { PromptNavigator.stops(in: items).count }

    var position: Int? {
        guard let current else { return nil }
        return PromptNavigator.stops(in: items).firstIndex(of: current).map { $0 + 1 }
    }

    // MARK: - Layout feedback from the view

    func updateLayout(tops: [Int: CGFloat], contentHeight: CGFloat) {
        // SwiftUI re-reports frames every animation frame with sub-point
        // pixel-rounding noise. Only a real change (font, width, or script)
        // should re-anchor, or auto-scroll keeps snapping back.
        guard Self.layoutChanged(from: self.tops, to: tops)
            || abs(contentHeight - self.contentHeight) > 1
        else { return }
        self.tops = tops
        self.contentHeight = contentHeight
        // Keep the current line on the reading line rather than drifting to
        // another one.
        anchorToCurrent(animated: false)
    }

    static func layoutChanged(from old: [Int: CGFloat], to new: [Int: CGFloat]) -> Bool {
        guard old.count == new.count else { return true }
        return new.contains { index, top in
            guard let previous = old[index] else { return true }
            return abs(previous - top) > 1
        }
    }

    /// The offset that puts the middle of an item's first line on the
    /// reading line.
    func targetOffset(for index: Int) -> CGFloat {
        let top = tops[index] ?? 0
        let item = items.indices.contains(index) ? items[index] : .line("")
        return top + PrompterLayout.fontSize(for: item, settings: settings) * 0.6
    }

    // MARK: - Navigation

    func next() { step(to: PromptNavigator.next(after: current, in: items)) }
    func previous() { step(to: PromptNavigator.previous(before: current, in: items)) }
    func restart() { step(to: PromptNavigator.first(in: items)) }
    func end() { step(to: PromptNavigator.last(in: items)) }

    private func step(to index: Int?) {
        guard let index else { return }
        current = index
        anchorToCurrent(animated: true)
    }

    private func anchorToCurrent(animated: Bool) {
        guard let current, tops[current] != nil else { return }
        let target = targetOffset(for: current)
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { offset = target }
        } else {
            offset = target
        }
    }

    /// Manual scrolling with a mouse wheel or trackpad.
    func nudge(by delta: CGFloat) {
        setOffset(offset + delta)
    }

    private func setOffset(_ value: CGFloat) {
        offset = min(max(value, 0), max(contentHeight, 0))
        let stop = PromptNavigator.stop(atOffset: offset, tops: tops, in: items)
        if stop != current { current = stop }
    }

    // MARK: - Auto-scroll

    func toggleScrolling() {
        isScrolling ? stopScrolling() : startScrolling()
    }

    func startScrolling() {
        guard !items.isEmpty, !isScrolling else { return }
        if offset >= contentHeight - 1 { restart() }
        isScrolling = true
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        isScrolling = false
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = min(now - lastTick, 0.1)
        lastTick = now
        setOffset(offset + CGFloat(settings.scrollSpeed * elapsed))
        if offset >= contentHeight { stopScrolling() }
    }

    func changeSpeed(by factor: Double) {
        settings.scrollSpeed = (settings.scrollSpeed * factor).rounded()
    }

    func changeFontSize(by delta: Double) {
        settings.fontSize += delta
    }
}

enum PrompterLayout {
    static func fontSize(for item: PromptItem, settings: PrompterSettings) -> CGFloat {
        let base = CGFloat(settings.fontSize)
        switch item.kind {
        case .line: return item.depth == 0 ? base : base * 0.88
        case .heading: return base * 0.5
        case .cue: return base * 0.5
        case .code: return base * 0.4
        }
    }

    static func indent(for item: PromptItem, settings: PrompterSettings) -> CGFloat {
        CGFloat(item.depth) * CGFloat(settings.fontSize) * 0.9
    }
}
