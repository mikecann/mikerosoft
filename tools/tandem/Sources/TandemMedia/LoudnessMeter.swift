import Foundation

/// ITU-R BS.1770-4 / EBU R128 loudness: integrated loudness (LUFS), loudness
/// range (LU) and true peak (dBTP).
///
/// Feed it float samples in any chunk size, then read `result()`. Used for
/// per-file analysis (levelling dialogue by take) and for the export's master
/// loudness pass.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double
    public let channels: Int

    private var shelf: [Biquad]
    private var highPass: [Biquad]
    private let weights: [Double]
    private let subBlockLength: Int
    private var subBlockFill = 0
    private var subBlockSums: [Double]
    /// Weighted mean square of each 100 ms sub-block, summed over channels.
    private var subBlocks: [Double] = []
    private var peaks: [TruePeak]

    public init(sampleRate: Double = 48_000, channels: Int = 2) {
        precondition(channels > 0, "LoudnessMeter needs at least one channel")
        self.sampleRate = sampleRate
        self.channels = channels
        shelf = Array(repeating: Biquad.kWeightingShelf(sampleRate: sampleRate), count: channels)
        highPass = Array(repeating: Biquad.kWeightingHighPass(sampleRate: sampleRate), count: channels)
        // 5.1 layouts skip the LFE and boost the surrounds; everything else
        // weighs every channel equally.
        weights = channels == 6 ? [1, 1, 1, 0, 1.41, 1.41] : Array(repeating: 1, count: channels)
        subBlockLength = max(1, Int((sampleRate * 0.1).rounded()))
        subBlockSums = Array(repeating: 0, count: channels)
        peaks = Array(repeating: TruePeak(), count: channels)
    }

    /// Adds interleaved samples (`frames * channels` values).
    public mutating func process(interleaved samples: UnsafeBufferPointer<Float>, frames: Int) {
        precondition(samples.count >= frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                add(Double(samples[frame * channels + channel]), channel: channel)
            }
            advance()
        }
    }

    /// Adds one buffer per channel, all the same length.
    public mutating func process(planar buffers: [UnsafeBufferPointer<Float>]) {
        precondition(buffers.count == channels)
        let frames = buffers.map(\.count).min() ?? 0
        for frame in 0..<frames {
            for channel in 0..<channels {
                add(Double(buffers[channel][frame]), channel: channel)
            }
            advance()
        }
    }

    public mutating func process(interleaved samples: [Float]) {
        samples.withUnsafeBufferPointer { process(interleaved: $0, frames: samples.count / channels) }
    }

    private mutating func add(_ sample: Double, channel: Int) {
        peaks[channel].add(sample)
        let weighted = highPass[channel].process(shelf[channel].process(sample))
        subBlockSums[channel] += weighted * weighted
    }

    private mutating func advance() {
        subBlockFill += 1
        guard subBlockFill == subBlockLength else { return }
        var total = 0.0
        for channel in 0..<channels {
            total += weights[channel] * subBlockSums[channel] / Double(subBlockLength)
            subBlockSums[channel] = 0
        }
        subBlocks.append(total)
        subBlockFill = 0
    }

    public func result() -> Loudness {
        Loudness(integratedLUFS: integrated, truePeakDBTP: truePeak, loudnessRange: loudnessRange)
    }

    /// Gated integrated loudness in LUFS, or -infinity for silence.
    public var integrated: Double {
        let blocks = windows(of: 4)
        let aboveAbsolute = blocks.filter { Self.lufs($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return -.infinity }
        let relativeGate = Self.lufs(mean(aboveAbsolute)) - 10
        let gated = aboveAbsolute.filter { Self.lufs($0) > relativeGate }
        guard !gated.isEmpty else { return -.infinity }
        return Self.lufs(mean(gated))
    }

    /// Loudness range in LU (EBU Tech 3342).
    public var loudnessRange: Double {
        let shortTerm = windows(of: 30).map(Self.lufs).filter { $0 > -70 }
        guard shortTerm.count > 1 else { return 0 }
        let energies = shortTerm.map { pow(10, ($0 + 0.691) / 10) }
        let relativeGate = Self.lufs(mean(energies)) - 20
        let gated = shortTerm.filter { $0 > relativeGate }.sorted()
        guard gated.count > 1 else { return 0 }
        func percentile(_ p: Double) -> Double {
            let index = min(gated.count - 1, max(0, Int((p * Double(gated.count - 1)).rounded())))
            return gated[index]
        }
        return percentile(0.95) - percentile(0.10)
    }

    /// Highest true peak across channels in dBTP.
    public var truePeak: Double {
        let peak = peaks.map(\.peak).max() ?? 0
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }

    /// Loudness of the last 3 s, for live meters.
    public var shortTerm: Double {
        guard subBlocks.count >= 30 else { return subBlocks.isEmpty ? -.infinity : Self.lufs(mean(Array(subBlocks))) }
        return Self.lufs(mean(Array(subBlocks.suffix(30))))
    }

    private func windows(of count: Int) -> [Double] {
        guard subBlocks.count >= count else { return [] }
        var result: [Double] = []
        result.reserveCapacity(subBlocks.count - count + 1)
        var sum = subBlocks[0..<count].reduce(0, +)
        result.append(sum / Double(count))
        for i in count..<subBlocks.count {
            sum += subBlocks[i] - subBlocks[i - count]
            result.append(max(0, sum) / Double(count))
        }
        return result
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    static func lufs(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }
}

/// A second-order IIR filter (transposed direct form II).
struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0
    var z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// BS.1770 stage 1: the head-related high shelf, derived for any rate
    /// (matches the published 48 kHz coefficients).
    static func kWeightingShelf(sampleRate fs: Double) -> Biquad {
        let f0 = 1681.974450955533
        let gain = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
    }

    /// BS.1770 stage 2: the RLB high-pass.
    static func kWeightingHighPass(sampleRate fs: Double) -> Biquad {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(Double.pi * f0 / fs)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
}

/// True-peak detection by 4x oversampling with a windowed-sinc
/// interpolator, per BS.1770-4 Annex 2.
struct TruePeak: Sendable {
    static let factor = 4
    static let tapsPerPhase = 12
    /// Coefficients for each phase, newest sample first, flattened.
    static let coefficients: [Double] = {
        let total = factor * tapsPerPhase
        let centre = Double(total - 1) / 2
        var taps = (0..<total).map { n -> Double in
            let x = (Double(n) - centre) / Double(factor)
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(total - 1))
            return sinc * window
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 * Double(factor) / sum }
        return (0..<factor).flatMap { phase in stride(from: phase, to: total, by: factor).map { taps[$0] } }
    }()

    /// The last `tapsPerPhase` samples, stored twice so the window is
    /// always contiguous: newest at `position + tapsPerPhase - 1`.
    var history = [Double](repeating: 0, count: TruePeak.tapsPerPhase * 2)
    var position = 0
    var peak = 0.0

    mutating func add(_ sample: Double) {
        let taps = Self.tapsPerPhase
        history[position] = sample
        history[position + taps] = sample
        position = (position + 1) % taps
        var best = max(peak, abs(sample))
        history.withUnsafeBufferPointer { h in
            Self.coefficients.withUnsafeBufferPointer { c in
                // Window oldest to newest is h[position ..< position + taps].
                let newest = position + taps - 1
                for phase in 0..<Self.factor {
                    var sum = 0.0
                    let base = phase * taps
                    for k in 0..<taps {
                        sum += c[base + k] * h[newest - k]
                    }
                    best = max(best, abs(sum))
                }
            }
        }
        peak = best
    }
}
