import CoreGraphics
import Foundation

/// An active CGEvent tap on its own thread, so a busy main thread can never
/// make the mouse lag.
final class EventTap {
    /// Return the same event to let it through, or nil to swallow it.
    typealias Handler = (CGEventType, CGEvent) -> CGEvent?

    fileprivate let handler: Handler
    private let mask: CGEventMask
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?

    init(events: [CGEventType], handler: @escaping Handler) {
        mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        self.handler = handler
    }

    /// Returns false when macOS refuses the tap, which means Accessibility
    /// permission is missing or has not reached this process yet.
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var started = false

        let thread = Thread { [self] in
            guard let port = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: eventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                ready.signal()
                return
            }

            let runLoop = CFRunLoopGetCurrent()!
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)

            // macOS switches a tap off when a callback is slow or after some
            // system events. Check now and then and switch it back on.
            let watchdog = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 5,
                5,
                0,
                0
            ) { _ in
                if !CGEvent.tapIsEnabled(tap: port) {
                    log("event tap was off, switching it back on")
                    CGEvent.tapEnable(tap: port, enable: true)
                }
            }
            CFRunLoopAddTimer(runLoop, watchdog, .commonModes)

            self.port = port
            self.runLoop = runLoop
            started = true
            ready.signal()

            CFRunLoopRun()

            CFRunLoopTimerInvalidate(watchdog)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(port)
        }
        thread.name = "Mikey Mouse event tap"
        thread.qualityOfService = .userInteractive
        thread.start()

        ready.wait()
        return started
    }

    /// Runs `cleanup` on the tap thread, then shuts the tap down.
    func stop(cleanup: (() -> Void)? = nil) {
        guard let runLoop, let port else {
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CGEvent.tapEnable(tap: port, enable: false)
            cleanup?()
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
        self.port = nil
    }

    fileprivate func reenableAfterTimeout() {
        log("event tap timed out, switching it back on")
        if let port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout:
        tap.reenableAfterTimeout()
        return Unmanaged.passUnretained(event)
    case .tapDisabledByUserInput:
        return Unmanaged.passUnretained(event)
    default:
        guard let result = tap.handler(type, event) else {
            return nil
        }
        return Unmanaged.passUnretained(result)
    }
}
