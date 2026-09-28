import CoreGraphics
import Foundation

enum SyntheticEvent {
    /// Written to `eventSourceUserData` on the scroll events Mikey Mouse posts.
    static let marker: Int64 = 0x4D_494B_4559
}

/// The parts of a scroll-wheel event that decide whether it gets smoothed.
struct ScrollInput: Equatable {
    var isContinuous: Bool
    var scrollPhase: Int64
    var momentumPhase: Int64
    var lineDeltaX: Int64
    var lineDeltaY: Int64
    var fixedDeltaX: Double
    var fixedDeltaY: Double
    var flags: CGEventFlags
    var isSynthetic: Bool
}

extension ScrollInput {
    init(event: CGEvent) {
        self.init(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            lineDeltaX: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            lineDeltaY: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            fixedDeltaX: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            fixedDeltaY: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            flags: event.flags,
            isSynthetic: event.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.marker
        )
    }
}

enum ScrollDecision: Equatable {
    case passThrough
    case smooth(x: Int, y: Int)
}

enum ScrollPolicy {
    /// Modifier scrolls keep their native meaning: Shift scrolls sideways, and
    /// Command, Control, or Option zoom or do something app-specific.
    static let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    /// Only notched-wheel ticks are smoothed. Trackpads and the Magic Mouse
    /// already send continuous, phased events.
    static func decide(_ input: ScrollInput, enabled: Bool) -> ScrollDecision {
        guard enabled,
              !input.isSynthetic,
              !input.isContinuous,
              input.scrollPhase == 0,
              input.momentumPhase == 0,
              input.flags.intersection(modifiers).isEmpty
        else {
            return .passThrough
        }

        let x = direction(line: input.lineDeltaX, fixed: input.fixedDeltaX)
        let y = direction(line: input.lineDeltaY, fixed: input.fixedDeltaY)
        guard x != 0 || y != 0 else {
            return .passThrough
        }

        return .smooth(x: x, y: y)
    }

    private static func direction(line: Int64, fixed: Double) -> Int {
        if line != 0 {
            return line > 0 ? 1 : -1
        }
        if fixed != 0 {
            return fixed > 0 ? 1 : -1
        }
        return 0
    }
}

enum SmoothScrollPoster {
    static func makeEvent(_ delta: PixelDelta, flags: CGEventFlags) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: delta.y),
            wheel2: Int32(clamping: delta.x),
            wheel3: 0
        ) else {
            return nil
        }

        // CoreGraphics marks pixel events as continuous and fills in the line
        // and point deltas, so apps treat them like trackpad scrolling.
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        event.flags = flags
        return event
    }

    static func post(_ delta: PixelDelta, flags: CGEventFlags) {
        makeEvent(delta, flags: flags)?.post(tap: .cgSessionEventTap)
    }
}

/// Runs the animator on the event-tap thread and posts one pixel scroll per
/// frame until the glide settles. Every method must run on that thread.
final class SmoothScroller {
    private static let frameInterval: CFTimeInterval = 1.0 / 120.0

    private var animator: ScrollAnimator
    private var timer: CFRunLoopTimer?
    private var flags: CGEventFlags = []
    private let debugLogging: Bool
    private var glideTicks = 0
    private var glidePixels = 0

    init(tuning: ScrollAnimator.Tuning, debugLogging: Bool) {
        animator = ScrollAnimator(tuning: tuning)
        self.debugLogging = debugLogging
    }

    func feed(x: Int, y: Int, flags: CGEventFlags, tuning: ScrollAnimator.Tuning) {
        animator.tuning = tuning
        self.flags = flags
        animator.addTicks(x: x, y: y, at: ProcessInfo.processInfo.systemUptime)
        glideTicks += 1
        startTimerIfNeeded()
    }

    func stop() {
        animator.stop()
        stopTimer()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else {
            return
        }

        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Self.frameInterval,
            Self.frameInterval,
            0,
            0
        ) { [weak self] _ in
            self?.tick()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        self.timer = timer
    }

    private func tick() {
        let delta = animator.advance(to: ProcessInfo.processInfo.systemUptime)
        if delta != .zero {
            SmoothScrollPoster.post(delta, flags: flags)
            glidePixels += abs(delta.x) + abs(delta.y)
        }

        if animator.isIdle {
            if debugLogging {
                log("glide finished: \(glideTicks) ticks, \(glidePixels) px")
            }
            glideTicks = 0
            glidePixels = 0
            stopTimer()
        }
    }

    private func stopTimer() {
        if let timer {
            CFRunLoopTimerInvalidate(timer)
        }
        timer = nil
    }
}
