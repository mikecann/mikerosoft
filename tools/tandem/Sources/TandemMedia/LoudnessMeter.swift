import Accelerate
import Foundation

/// ITU-R BS.1770-4 / EBU R128 loudness: integrated loudness (LUFS), loudness
/// range (LU) and true peak (dBTP).
///
/// Feed it float samples in any chunk size, then read `result()`. Used for
/// per-file analysis (levelling dialogue by take) and for the export's master
/// loudness pass.
///
/// The filtering runs through Accelerate (vDSP biquads and convolutions in
/// double precision), so a 24 minute stereo file measures in about a second.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double
    public let channels: Int

    /// The two K-weighting stages as one two-section vDSP biquad.
    private let kWeighting: BiquadSetup
    /// vDSP biquad state per channel (2 * sections + 2 values).
    private var delays: [[Double]]
    private let weights: [Double]
    private let subBlockLength: Int
    private var subBlockFill = 0
    private var subBlockSums: [Double]
    /// Weighted mean square of each 100 ms sub-block, summed over channels.
    private var subBlocks: [Double] = []
    /// The last `TruePeak.tapsPerPhase - 1` input samples per channel, so the
    /// oversampling filter runs across chunk boundaries.
    private var peakHistory: [[Double]]
    private var peak = 0.0

    public init(sampleRate: Double = 48_000, channels: Int = 2) {
        precondition(channels > 0, "LoudnessMeter needs at least one channel")
        self.sampleRate = sampleRate
        self.channels = channels
        kWeighting = BiquadSetup(sections: [
            Biquad.kWeightingShelf(sampleRate: sampleRate),
            Biquad.kWeightingHighPass(sampleRate: sampleRate)
        ])
        delays = Array(repeating: [Double](repeating: 0, count: 2 * 2 + 2), count: channels)
        // 5.1 layouts skip the LFE and boost the surrounds; everything else
        // weighs every channel equally.
        weights = channels == 6 ? [1, 1, 1, 0, 1.41, 1.41] : Array(repeating: 1, count: channels)
        subBlockLength = max(1, Int((sampleRate * 0.1).rounded()))
        subBlockSums = Array(repeating: 0, count: channels)
        peakHistory = Array(repeating: [Double](repeating: 0, count: TruePeak.tapsPerPhase - 1), count: channels)
    }

    /// Adds interleaved samples (`frames * channels` values).
    public mutating func process(interleaved samples: UnsafeBufferPointer<Float>, frames: Int) {
        precondition(samples.count >= frames * channels)
        guard frames > 0, let base = samples.baseAddress else { return }
        var input = [Double](repeating: 0, count: frames)
        var filtered = [[Double]](repeating: [], count: channels)
        for channel in 0..<channels {
            input.withUnsafeMutableBufferPointer { out in
                vDSP_vspdp(base + channel, vDSP_Stride(channels), out.baseAddress!, 1, vDSP_Length(frames))
            }
            filtered[channel] = measure(channel: channel, input: input)
        }
        accumulate(filtered, frames: frames)
    }

    /// Adds one buffer per channel, all the same length.
    public mutating func process(planar buffers: [UnsafeBufferPointer<Float>]) {
        precondition(buffers.count == channels)
        let frames = buffers.map(\.count).min() ?? 0
        guard frames > 0 else { return }
        var input = [Double](repeating: 0, count: frames)
        var filtered = [[Double]](repeating: [], count: channels)
        for channel in 0..<channels {
            input.withUnsafeMutableBufferPointer { out in
                vDSP_vspdp(buffers[channel].baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(frames))
            }
            filtered[channel] = measure(channel: channel, input: input)
        }
        accumulate(filtered, frames: frames)
    }

    public mutating func process(interleaved samples: [Float]) {
        samples.withUnsafeBufferPointer { process(interleaved: $0, frames: samples.count / channels) }
    }

    /// Updates the true peak from one channel's samples and returns them
    /// K-weighted.
    private mutating func measure(channel: Int, input: [Double]) -> [Double] {
        let frames = input.count
        let taps = TruePeak.tapsPerPhase

        // True peak: 4x oversampling as four polyphase FIR filters over the
        // history plus this chunk, and the samples themselves.
        var extended = peakHistory[channel]
        extended.append(contentsOf: input)
        var phaseOutput = [Double](repeating: 0, count: frames)
        var best = 0.0
        input.withUnsafeBufferPointer { x in
            vDSP_maxmgvD(x.baseAddress!, 1, &best, vDSP_Length(frames))
        }
        extended.withUnsafeBufferPointer { e in
            TruePeak.coefficients.withUnsafeBufferPointer { c in
                phaseOutput.withUnsafeMutableBufferPointer { out in
                    for phase in 0..<TruePeak.factor {
                        // A negative filter stride from the last tap turns
                        // vDSP's correlation into the convolution we want.
                        let lastTap = c.baseAddress! + phase * taps + taps - 1
                        vDSP_convD(e.baseAddress!, 1, lastTap, -1, out.baseAddress!, 1, vDSP_Length(frames), vDSP_Length(taps))
                        var phasePeak = 0.0
                        vDSP_maxmgvD(out.baseAddress!, 1, &phasePeak, vDSP_Length(frames))
                        best = max(best, phasePeak)
                    }
                }
            }
        }
        peak = max(peak, best)
        peakHistory[channel] = Array(extended.suffix(taps - 1))

        // K-weighting.
        let setup = kWeighting.setup
        var output = [Double](repeating: 0, count: frames)
        input.withUnsafeBufferPointer { x in
            output.withUnsafeMutableBufferPointer { y in
                delays[channel].withUnsafeMutableBufferPointer { delay in
                    vDSP_biquadD(setup, delay.baseAddress!, x.baseAddress!, 1, y.baseAddress!, 1, vDSP_Length(frames))
                }
            }
        }
        return output
    }

    /// Adds the weighted energy to 100 ms sub-blocks.
    private mutating func accumulate(_ filtered: [[Double]], frames: Int) {
        var offset = 0
        while offset < frames {
            let count = min(subBlockLength - subBlockFill, frames - offset)
            for channel in 0..<channels {
                var sum = 0.0
                filtered[channel].withUnsafeBufferPointer { y in
                    vDSP_svesqD(y.baseAddress! + offset, 1, &sum, vDSP_Length(count))
                }
                subBlockSums[channel] += sum
            }
            subBlockFill += count
            offset += count
            if subBlockFill == subBlockLength {
                var total = 0.0
                for channel in 0..<channels {
                    total += weights[channel] * subBlockSums[channel] / Double(subBlockLength)
                    subBlockSums[channel] = 0
                }
                subBlocks.append(total)
                subBlockFill = 0
            }
        }
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
        peak > 0 ? 20 * log10(peak) : -.infinity
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

/// Second-order IIR coefficients, in vDSP's sign convention
/// (y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2).
struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Double

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

/// Owns a vDSP biquad setup. Immutable once made, so it's safe to share.
final class BiquadSetup: @unchecked Sendable {
    let setup: vDSP_biquad_SetupD

    init(sections: [Biquad]) {
        let coefficients = sections.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
        setup = vDSP_biquad_CreateSetupD(coefficients, vDSP_Length(sections.count))!
    }

    deinit { vDSP_biquad_DestroySetupD(setup) }
}

/// True-peak detection by 4x oversampling with a windowed-sinc
/// interpolator, per BS.1770-4 Annex 2.
enum TruePeak {
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
}
