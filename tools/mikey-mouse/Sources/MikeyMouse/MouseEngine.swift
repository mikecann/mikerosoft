import CoreGraphics
import Foundation

/// Routes side-button presses and wheel ticks from the event tap.
final class MouseEngine {
    private let settings: SettingsStore
    private var tap: EventTap?

    // Only touched on the event-tap thread.
    private var buttons = SideButtonState()
    private var scroller: SmoothScroller?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var isRunning: Bool {
        tap != nil
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else {
            return true
        }

        let tap = EventTap(events: [.otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel]) {
            [unowned self] type, event in
            handle(type, event)
        }
        guard tap.start() else {
            return false
        }

        self.tap = tap
        return true
    }

    func stop() {
        tap?.stop { [self] in
            scroller?.stop()
            scroller = nil
            buttons = SideButtonState()
        }
        tap = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .scrollWheel:
            return handleScroll(event)
        case .otherMouseDown:
            return handleSideButtonDown(event)
        case .otherMouseDragged:
            return buttons.swallowsDrag(button: buttonNumber(of: event)) ? nil : event
        case .otherMouseUp:
            return buttons.mouseUp(button: buttonNumber(of: event)) ? nil : event
        default:
            return event
        }
    }

    private func handleScroll(_ event: CGEvent) -> CGEvent? {
        let current = settings.current
        let decision = ScrollPolicy.decide(ScrollInput(event: event), enabled: current.smoothScrollingEnabled)
        guard case let .smooth(x, y) = decision else {
            return event
        }

        let scroller = scroller ?? SmoothScroller(
            tuning: current.scrollTuning,
            debugLogging: settings.debugLogging
        )
        self.scroller = scroller
        scroller.feed(x: x, y: y, flags: event.flags, tuning: current.scrollTuning)
        return nil
    }

    private func handleSideButtonDown(_ event: CGEvent) -> CGEvent? {
        let button = buttonNumber(of: event)
        guard button == BackForwardRouter.backButton || button == BackForwardRouter.forwardButton else {
            return event
        }

        let enabled = settings.current.backForwardEnabled
        let bundleID = enabled ? TargetApp.bundleIdentifier(for: event) : nil
        let direction = BackForwardRouter.direction(
            forButton: button,
            targetBundleID: bundleID,
            enabled: enabled
        )

        switch buttons.mouseDown(button: button, direction: direction) {
        case .passThrough:
            log("button \(button + 1) over \(bundleID ?? "unknown app"): left alone")
            return event
        case let .swipe(direction):
            log("button \(button + 1) over \(bundleID ?? "unknown app"): \(direction) swipe")
            NavigationSwipe.post(direction)
            return nil
        }
    }

    private func buttonNumber(of event: CGEvent) -> Int64 {
        event.getIntegerValueField(.mouseEventButtonNumber)
    }
}
