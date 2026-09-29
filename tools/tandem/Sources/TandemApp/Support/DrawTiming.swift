import AppKit
import QuartzCore

/// Recent draw times per view, for checking the timeline stays smooth on
/// big projects. `tandem://debug` writes them out (and `reset=1` starts
/// them afresh, to time one gesture).
@MainActor
enum DrawTiming {
    enum Unit {
        case seconds
        /// A share of something, like the part of a view a draw covered.
        case fraction
    }

    private static var samples: [String: [Double]] = [:]
    private static var units: [String: Unit] = [:]
    /// Samples kept per name: a few seconds of a busy gesture.
    static let capacity = 1_000

    static func record(_ name: String, _ value: Double, unit: Unit = .seconds) {
        var list = samples[name, default: []]
        list.append(value)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        samples[name] = list
        units[name] = unit
    }

    static func reset() {
        samples = [:]
    }

    /// The samples recorded under `name`, oldest first.
    static func samples(_ name: String) -> [Double] {
        samples[name] ?? []
    }

    static var summary: String {
        samples.keys.sorted().map { name in
            let list = samples[name] ?? []
            let sorted = list.sorted()
            let total = list.reduce(0, +)
            let average = total / Double(max(list.count, 1))
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let largest = sorted.last ?? 0
            if units[name] == .fraction {
                return String(format: "%@: %d draws, average %.1f%%, p95 %.1f%%, max %.1f%%", name, list.count, average * 100, p95 * 100, largest * 100)
            }
            return String(
                format: "%@: %d draws, average %.2f ms, p95 %.2f ms, max %.2f ms, total %.1f ms",
                name, list.count, average * 1000, p95 * 1000, largest * 1000, total * 1000
            )
        }.joined(separator: "\n")
    }
}

extension CGRect {
    /// Width times height, and 0 for the null rectangle.
    var area: CGFloat { isNull ? 0 : width * height }
}

/// How long the main thread stays busy each time it wakes, the measure of
/// how blocked input is. Each wake is timed from the run loop waking to it
/// going back to sleep, into `DrawTiming` as "main thread busy". The part
/// spent in run loop observers (SwiftUI's updates, layout, drawing and Core
/// Animation's commit, including any wait for the screen to take the last
/// frame) goes in as "display"; the rest is handling events, timers and
/// queued work.
@MainActor
enum MainThreadMeter {
    private static var observers: [CFRunLoopObserver] = []
    private static var wokeAt: CFTimeInterval?
    private static var observersStartedAt: CFTimeInterval?
    private static var display: CFTimeInterval = 0

    static func install() {
        guard observers.isEmpty else { return }
        // Around every other observer: AppKit commits on the way out of
        // the run loop after each event as well as before it sleeps.
        let first = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, CFIndex.min) { _, activity in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    wokeAt = now
                    display = 0
                }
                observersStartedAt = now
            }
        }
        let last = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated { observersFinished(sleeping: activity == .beforeWaiting) }
        }
        for observer in [first, last].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    private static func observersFinished(sleeping: Bool) {
        let now = CACurrentMediaTime()
        if let observersStartedAt { display += now - observersStartedAt }
        observersStartedAt = nil
        guard sleeping, let wokeAt else { return }
        DrawTiming.record("main thread busy", now - wokeAt)
        DrawTiming.record("display", display)
        self.wokeAt = nil
        display = 0
    }
}
