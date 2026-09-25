import Foundation

/// A lookahead true-peak limiter for the master bus.
///
/// Peaks are found between samples by 4x oversampling (the same windowed
/// sinc the loudness meter uses), so the output stays under the ceiling in
/// dBTP, not just in sample peaks. Gain reduction is held over the
/// lookahead window and averaged across it, so it ramps down smoothly
/// before a peak arrives and never lets one through, then recovers
/// exponentially. Channels share one gain so the stereo image doesn't move.
///
/// The output is delayed by `latency` samples: drop that many from the
/// start of the output and call `flush()` at the end to keep sync.
struct TruePeakLimiter {
    let channels: Int
    let sampleRate: Double
    /// Linear ceiling.
    let ceiling: Double
    let lookahead: Int
    /// Samples between an input and its limited output.
    var latency: Int { lookahead + Self.detectorDelay }

    static let oversampling = 4
    static let tapsPerPhase = 12
    /// The interpolator's window is centred this many samples behind the
    /// newest input.
    static let detectorDelay = tapsPerPhase / 2
    static let coefficients: [Double] = {
        let total = oversampling * tapsPerPhase
        let centre = Double(total - 1) / 2
        var taps = (0..<total).map { n -> Double in
            let x = (Double(n) - centre) / Double(oversampling)
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(total - 1))
            return sinc * window
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 * Double(oversampling) / sum }
        return (0..<oversampling).flatMap { phase in stride(from: phase, to: total, by: oversampling).map { taps[$0] } }
    }()

    private let releaseCoefficient: Double
    /// Below this no inter-sample peak can plausibly reach the ceiling, so
    /// the interpolator is skipped.
    private let quietLevel: Double

    /// Per channel: the last `tapsPerPhase` inputs, stored twice so the
    /// window is always contiguous.
    private var history: [[Double]]
    private var historyPosition = 0
    /// Interleaved input delayed by `latency` samples.
    private var delayLine: [Float]
    private var delayPosition = 0
    /// Sliding minimum of the required gain over the lookahead window.
    private var minimumQueue: [(index: Int, gain: Double)] = []
    private var minimumHead = 0
    /// Held gains for the averaging window.
    private var heldGains: [Double]
    private var heldPosition = 0
    private var heldSum: Double
    private var gain = 1.0
    private var inputIndex = 0
    /// How many upcoming detector steps must run the interpolator.
    private var hotSamples = 0

    init(channels: Int, sampleRate: Double = 48_000, ceilingDBTP: Double, lookaheadSeconds: Double = 0.005, releaseSeconds: Double = 0.08) {
        precondition(channels > 0)
        self.channels = channels
        self.sampleRate = sampleRate
        // Aim a touch under the ceiling so the 4x estimate's small error
        // (and the encoder's) doesn't poke over it.
        self.ceiling = pow(10, (ceilingDBTP - 0.1) / 20)
        self.lookahead = max(1, Int((lookaheadSeconds * sampleRate).rounded()))
        self.releaseCoefficient = 1 - exp(-1 / (releaseSeconds * sampleRate))
        self.quietLevel = self.ceiling / 2
        history = Array(repeating: Array(repeating: 0, count: Self.tapsPerPhase * 2), count: channels)
        delayLine = Array(repeating: 0, count: (lookahead + Self.detectorDelay) * channels)
        heldGains = Array(repeating: 1, count: lookahead + 1)
        heldSum = Double(lookahead + 1)
    }

    /// Limits interleaved samples in place. The result is the input from
    /// `latency` samples earlier, limited.
    mutating func process(_ samples: UnsafeMutableBufferPointer<Float>, frames: Int) {
        for frame in 0..<frames {
            let base = frame * channels
            // 1. Required gain for the sample the interpolator is centred on.
            var peak = 0.0
            var loudInput = false
            for c in 0..<channels {
                let x = Double(samples[base + c])
                if abs(x) > quietLevel { loudInput = true }
                history[c][historyPosition] = x
                history[c][historyPosition + Self.tapsPerPhase] = x
            }
            if loudInput { hotSamples = Self.tapsPerPhase + 1 }
            historyPosition = (historyPosition + 1) % Self.tapsPerPhase
            if hotSamples > 0 {
                hotSamples -= 1
                for c in 0..<channels {
                    peak = max(peak, truePeak(channel: c))
                }
            }
            let required = peak > ceiling ? ceiling / peak : 1

            // 2. Hold: the smallest required gain over the lookahead window,
            // plus one step, since a peak between two samples needs both of
            // them turned down.
            let index = inputIndex
            inputIndex += 1
            while minimumQueue.count > minimumHead, minimumQueue[minimumQueue.count - 1].gain >= required {
                minimumQueue.removeLast()
            }
            minimumQueue.append((index, required))
            while minimumQueue[minimumHead].index <= index - lookahead - 2 {
                minimumHead += 1
            }
            if minimumHead > 1024 {
                minimumQueue.removeFirst(minimumHead)
                minimumHead = 0
            }
            let held = minimumQueue[minimumHead].gain

            // 3. Average the held gain over the window, so reduction ramps in
            // across the lookahead and is complete when the peak arrives.
            heldSum += held - heldGains[heldPosition]
            heldGains[heldPosition] = held
            heldPosition = (heldPosition + 1) % heldGains.count
            let smoothed = min(1, heldSum / Double(heldGains.count))

            // 4. Attack instantly to the smoothed gain, release slowly.
            gain = smoothed < gain ? smoothed : gain + (smoothed - gain) * releaseCoefficient

            // 5. Swap the input into the delay line and output the sample
            // from `latency` steps ago with this gain.
            for c in 0..<channels {
                let delayed = delayLine[delayPosition * channels + c]
                delayLine[delayPosition * channels + c] = samples[base + c]
                samples[base + c] = Float(Double(delayed) * gain)
            }
            delayPosition = (delayPosition + 1) % (delayLine.count / channels)
        }
    }

    mutating func process(_ samples: inout [Float]) {
        let frames = samples.count / channels
        samples.withUnsafeMutableBufferPointer { process($0, frames: frames) }
    }

    /// The last `latency` samples, pushed out with silence.
    mutating func flush() -> [Float] {
        var tail = [Float](repeating: 0, count: latency * channels)
        process(&tail)
        return tail
    }

    /// The largest interpolated magnitude around the centre of the window.
    private func truePeak(channel c: Int) -> Double {
        let taps = Self.tapsPerPhase
        let newest = historyPosition + taps - 1
        var best = 0.0
        history[c].withUnsafeBufferPointer { h in
            Self.coefficients.withUnsafeBufferPointer { k in
                for phase in 0..<Self.oversampling {
                    var sum = 0.0
                    let offset = phase * taps
                    for i in 0..<taps {
                        sum += k[offset + i] * h[newest - i]
                    }
                    best = max(best, abs(sum))
                }
                // The sample at the centre itself.
                best = max(best, abs(h[newest - Self.detectorDelay]))
            }
        }
        return best
    }
}
