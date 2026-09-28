import Foundation

struct PixelDelta: Equatable {
    var x: Int
    var y: Int

    static let zero = PixelDelta(x: 0, y: 0)
}

/// Turns notched scroll-wheel ticks into a stream of small pixel deltas.
///
/// Each tick adds distance to travel. Every frame moves a fixed fraction of the
/// distance that is left, so motion starts fast and eases out. Ticks that
/// arrive quickly travel further, which is how a fast flick covers a page.
struct ScrollAnimator {
    struct Tuning: Equatable {
        /// Distance one slow tick travels.
        var pixelsPerTick: Double
        /// Seconds for the remaining distance to shrink to about 37%.
        var timeConstant: TimeInterval
        /// Ticks this far apart, or further, travel exactly `pixelsPerTick`.
        var accelerationThreshold: TimeInterval = 0.125
        /// Extra steps per tick for each multiple of the threshold tick rate.
        var accelerationGain = 0.5
        var maxAcceleration = 5.0

        func acceleration(forInterval interval: TimeInterval?) -> Double {
            guard let interval, interval < accelerationThreshold else {
                return 1
            }

            let rate = accelerationThreshold / max(interval, 0.001)
            return min(maxAcceleration, 1 + accelerationGain * (rate - 1))
        }
    }

    private struct Axis {
        var remaining = 0.0
        var carry = 0.0
        var direction = 0
        var lastTickTime: TimeInterval?
        var smoothedInterval: TimeInterval?

        var isIdle: Bool {
            remaining == 0 && carry == 0
        }

        mutating func addTicks(_ ticks: Int, at time: TimeInterval, tuning: Tuning) {
            guard ticks != 0 else {
                return
            }

            let newDirection = ticks > 0 ? 1 : -1
            if newDirection != direction {
                // Scrolling the other way should stop at once, not after the
                // previous tick finishes gliding.
                self = Axis()
                direction = newDirection
            }

            if let lastTickTime {
                let interval = max(time - lastTickTime, 0)
                if interval > tuning.accelerationThreshold * 2 {
                    smoothedInterval = nil
                } else {
                    smoothedInterval = smoothedInterval.map { ($0 + interval) / 2 } ?? interval
                }
            }
            lastTickTime = time

            let boost = tuning.acceleration(forInterval: smoothedInterval)
            remaining += Double(ticks) * tuning.pixelsPerTick * boost
        }

        mutating func advance(fraction: Double) -> Int {
            guard !isIdle else {
                return 0
            }

            var step = remaining * fraction
            if abs(remaining - step) < ScrollAnimator.settleThreshold {
                step = remaining
            }
            remaining -= step
            carry += step

            if remaining == 0 {
                let whole = carry.rounded()
                carry = 0
                return Int(whole)
            }

            let whole = carry.rounded(.towardZero)
            carry -= whole
            return Int(whole)
        }
    }

    private static let settleThreshold = 0.5
    private static let frameInterval: TimeInterval = 1.0 / 120.0
    private static let maxFrameInterval: TimeInterval = 0.05

    var tuning: Tuning
    private var x = Axis()
    private var y = Axis()
    private var lastFrameTime: TimeInterval?

    init(tuning: Tuning) {
        self.tuning = tuning
    }

    var isIdle: Bool {
        x.isIdle && y.isIdle
    }

    mutating func addTicks(x ticksX: Int, y ticksY: Int, at time: TimeInterval) {
        if isIdle {
            lastFrameTime = time
        }
        x.addTicks(ticksX, at: time, tuning: tuning)
        y.addTicks(ticksY, at: time, tuning: tuning)
    }

    mutating func advance(to time: TimeInterval) -> PixelDelta {
        guard !isIdle else {
            lastFrameTime = nil
            return .zero
        }

        let previous = lastFrameTime ?? time - Self.frameInterval
        let dt = min(max(time - previous, 0), Self.maxFrameInterval)
        lastFrameTime = time

        let fraction = 1 - exp(-dt / tuning.timeConstant)
        return PixelDelta(x: x.advance(fraction: fraction), y: y.advance(fraction: fraction))
    }

    mutating func stop() {
        x = Axis()
        y = Axis()
        lastFrameTime = nil
    }
}
